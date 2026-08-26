import Foundation

// libpm3 C ABI
typealias PM3OpenFunc        = @convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?
typealias PM3ConsoleFunc     = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Bool, Bool) -> Int32
typealias PM3CloseFunc       = @convention(c) (OpaquePointer?) -> Void

// Tiny mutex-protected box for cross-thread mutable state (Sendable-safe).
final class MutexBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { self.value = initial }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool = false
    func load() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
    func store(_ x: Bool) { lock.lock(); defer { lock.unlock() }; v = x }
}

enum RunnerError: Error, LocalizedError {
    case binaryNotFound
    case pipeFailed
    case spawnFailed(Int32)
    case dlopenFailed(String)
    case dlsymFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:    return "pm3client binary not found in app bundle"
        case .pipeFailed:        return "Failed to create stdio pipes"
        case .spawnFailed(let e): return "spawn failed: errno \(e)"
        case .dlopenFailed(let s): return "dlopen failed: \(s)"
        case .dlsymFailed(let s): return "dlsym failed: \(s)"
        }
    }
}

@MainActor
final class BinaryRunner: ObservableObject {
    @Published var isRunning = false
    @Published var processStatus = "Not started"

    private var pid: pid_t = -1
    private var stdoutReadFD: Int32 = -1
    private var stdinWriteFD: Int32 = -1
    // Serial-port pair created during launch — master is kept for TcpTransport relay
    private(set) var portMasterFD: Int32 = -1

    // libpm3 command pump
    fileprivate var pm3Console: PM3ConsoleFunc?
    fileprivate let cmdQueue   = MutexBox<[String]>([])
    fileprivate let cmdSema    = DispatchSemaphore(value: 0)
    fileprivate let shouldQuit = AtomicBool()

    private(set) var outputStream: AsyncStream<String>
    private var outputContinuation: AsyncStream<String>.Continuation

    // Persisted so we can kill the orphan after a force-quit/crash
    private static let pgidKey = "com.proxbuddy.pm3.pgid"

    init() {
        (outputStream, outputContinuation) = AsyncStream.makeStream(of: String.self)
        signal(SIGPIPE, SIG_IGN)
    }

    /// Recreates the output stream so the runner can be launched again after a crash or
    /// clean exit (the old continuation is finished and can't accept new output).
    /// Call this before launch() on a runner that has previously run.
    func resetStream() {
        outputContinuation.finish()  // no-op if already finished; safe to call again
        (outputStream, outputContinuation) = AsyncStream.makeStream(of: String.self)
        isRunning     = false
        processStatus = "Not started"
        portMasterFD  = -1
    }

    /// Kill any pm3 process group left over from a previous session that ended without
    /// calling terminate() — e.g. app force-killed from Xcode or springboard.
    private func reapOrphan() async {
        let stored = pid_t(UserDefaults.standard.integer(forKey: Self.pgidKey))
        guard stored > 0 else { return }
        killpg(stored, SIGTERM)
        UserDefaults.standard.removeObject(forKey: Self.pgidKey)
        // Give the OS a moment to release the serial port before we try to reopen it
        try? await Task.sleep(for: .milliseconds(400))
    }

    // MARK: - Launch

    /// Production (real device): finds the best binary and creates the serial-port pair
    /// internally. The master FD is stored in portMasterFD for TcpTransport to relay.
    func launch() async throws {
        let bundledURL = Bundle.main.url(forResource: "libpm3client", withExtension: "dylib", subdirectory: "Frameworks")
            ?? Bundle.main.url(forResource: "libpm3client", withExtension: "dylib")
        guard let binaryURL = bundledURL else {
            throw RunnerError.binaryNotFound
        }
        try await launchWithPortPair(binaryPath: binaryURL.path)
    }

    /// LIBPM3 mode — dlopen the dylib, resolve pm3_open/console/close, then run a
    /// dedicated 8MB-stack thread that opens pm3 in OFFLINE mode and pumps commands
    /// from cmdQueue. Output is captured via stdout/stderr redirect to socketpair.
    private func launchWithPortPair(binaryPath: String) async throws {
        await reapOrphan()

        let pm3Home = PM3HomeSetup.prepare(binaryPath: binaryPath)

        guard let handle = dlopen(binaryPath, RTLD_NOW | RTLD_GLOBAL) else {
            let err = String(cString: dlerror())
            throw RunnerError.dlopenFailed(err)
        }
        let (stdoutMaster, stdoutSlave, stdoutIsPTY)  = try Self.openPair()

        if stdoutIsPTY {
            var outTios = termios()
            tcgetattr(stdoutMaster, &outTios)
            outTios.c_oflag &= ~UInt(OPOST)
            outTios.c_lflag &= ~UInt(ECHO | ECHOE | ECHOK | ECHONL)
            tcsetattr(stdoutMaster, TCSANOW, &outTios)
        }

        // Create a local TCP loopback server to bypass iOS /dev/fd/ sandbox restrictions.
        // C client will connect to "tcp:127.0.0.1:<port>", giving us a secure, sandboxed socket.
        let serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            close(stdoutMaster); close(stdoutSlave)
            throw RunnerError.pipeFailed
        }
        var opt: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(0).bigEndian // Random free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        var bindAddr = sockaddr()
        memcpy(&bindAddr, &addr, MemoryLayout<sockaddr_in>.size)

        guard Darwin.bind(serverFD, &bindAddr, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
            close(stdoutMaster); close(stdoutSlave); close(serverFD)
            throw RunnerError.pipeFailed
        }
        guard Darwin.listen(serverFD, 1) == 0 else {
            close(stdoutMaster); close(stdoutSlave); close(serverFD)
            throw RunnerError.pipeFailed
        }

        // Get the dynamically allocated port
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var sin = sockaddr_in()
        withUnsafeMutablePointer(to: &sin) { sinPtr in
            sinPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                _ = getsockname(serverFD, sockaddrPtr, &len)
            }
        }
        let localPort = UInt16(bigEndian: sin.sin_port)
        let connectionString = "tcp:127.0.0.1:\(localPort)"

        guard let openSym    = dlsym(handle, "pm3_open"),
              let consoleSym = dlsym(handle, "pm3_console"),
              let closeSym   = dlsym(handle, "pm3_close") else {
            let err = String(cString: dlerror())
            dlclose(handle)
            close(stdoutMaster); close(stdoutSlave); close(serverFD)
            throw RunnerError.dlsymFailed(err)
        }
        let pm3Open    = unsafeBitCast(openSym,    to: PM3OpenFunc.self)
        let pm3Console = unsafeBitCast(consoleSym, to: PM3ConsoleFunc.self)
        let pm3Close   = unsafeBitCast(closeSym,   to: PM3CloseFunc.self)

        let savedStdout = dup(STDOUT_FILENO)

        self.stdoutReadFD  = stdoutMaster
        self.isRunning     = true
        self.processStatus = "Running (libpm3)"

        startOutputReader(fd: stdoutMaster, origOut: savedStdout)

        // Redirect ONLY process-wide stdout to the capture pipe. We DO NOT redirect stderr, 
        // because Apple's internal iOS constraint warnings and SwiftUI logs print to stderr, 
        // and we don't want them appearing inside the app's terminal UI!
        dup2(stdoutSlave, STDOUT_FILENO)
        close(stdoutSlave)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        setenv("HOME", docs.path, 1)
        setenv("TERM", "xterm-256color", 1)
        setenv("PM3HOME", pm3Home, 1)

        self.pm3Console = pm3Console
        let cmdQueue    = self.cmdQueue
        let cmdSema     = self.cmdSema
        let shouldQuit  = self.shouldQuit

        // Use Swift concurrency to wait for the local socket to accept without blocking the main thread
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Start local accept thread
            Thread { [weak self] in
                var clientAddr = sockaddr()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr>.size)
                let fd = Darwin.accept(serverFD, &clientAddr, &clientAddrLen)
                close(serverFD)
                
                Task { @MainActor in
                    if fd >= 0 {
                        self?.portMasterFD = fd
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: RunnerError.pipeFailed)
                    }
                }
            }.start()

            let thread = Thread { [weak self] in
                // Open the C client, pointing it to our local TCP loopback
                // This connect() will unblock the Darwin.accept thread above
                let dev = pm3Open(connectionString)

                // Print the initial prompt so the UI and capture logic knows it's ready
                fputs("pm3 --> ", stdout)
                fflush(stdout)

                while !shouldQuit.load() {
                    cmdSema.wait()
                    if shouldQuit.load() { break }
                    let cmd: String? = cmdQueue.withLock { q in
                        q.isEmpty ? nil : q.removeFirst()
                    }
                    guard let cmd else { continue }
                    cmd.withCString { _ = pm3Console(dev, $0, false, false) }
                    
                    // Signal command completion to the UI parser
                    fputs("\npm3 --> ", stdout)
                    fflush(stdout)
                }
                pm3Close(dev)

                close(STDOUT_FILENO)
                if savedStdout >= 0 { dup2(savedStdout, STDOUT_FILENO); close(savedStdout) }

                Task { @MainActor in
                    self?.isRunning = false
                    self?.processStatus = "Exited"
                }
            }
            thread.name = "pm3-libpm3"
            thread.stackSize = 8 * 1024 * 1024
            thread.start()
        }
    }

    /// Simulator path — spawn the native macOS pm3 binary as a subprocess with the
    /// real USB serial port. This gives us full hardware access and `pm3_present = true`.
    func launch(binaryPath: String, portPath: String) async throws {
        await reapOrphan()

        // Create a PTY so the native binary runs interactively (prints prompts)
        let (master, slave, isPTY) = try Self.openPair()

        if isPTY {
            var outTios = termios()
            tcgetattr(master, &outTios)
            outTios.c_oflag &= ~UInt(OPOST)
            outTios.c_lflag &= ~UInt(ECHO | ECHOE | ECHOK | ECHONL)
            tcsetattr(master, TCSANOW, &outTios)
        }

        // posix_spawn file actions: redirect child stdin/stdout/stderr to the PTY slave
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, master)
        posix_spawn_file_actions_addclose(&fileActions, slave)

        // Spawn attributes: start a new process group so we can kill cleanly
        var spawnAttr: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttr)
        posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&spawnAttr, 0)

        // Build argv: proxmark3 <port>
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(binaryPath),
            strdup(portPath),
            nil
        ]
        defer { for p in argv { free(p) } }

        // Environment
        let pm3Home = PM3HomeSetup.prepare(binaryPath: binaryPath)
        let env: [UnsafeMutablePointer<CChar>?] = [
            strdup("HOME=\(NSHomeDirectory())"),
            strdup("TERM=xterm-256color"),
            strdup("PM3HOME=\(pm3Home)"),
            strdup("PATH=/usr/bin:/usr/local/bin:/opt/homebrew/bin"),
            nil
        ]
        defer { for p in env { free(p) } }

        var childPid: pid_t = 0
        let rc = posix_spawn(&childPid, binaryPath, &fileActions, &spawnAttr, argv, env)
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&spawnAttr)

        // Close the slave end in the parent
        close(slave)

        guard rc == 0 else {
            close(master)
            throw RunnerError.spawnFailed(rc)
        }

        self.pid           = childPid
        self.stdoutReadFD  = master
        self.stdinWriteFD  = dup(master)  // dup so terminate() can safely close both
        self.portMasterFD  = -1
        self.isRunning     = true
        self.processStatus = "Running (pid \(childPid))"

        // Persist the process group so we can reap orphans on next launch
        let pgid = getpgid(childPid)
        UserDefaults.standard.set(Int(pgid), forKey: Self.pgidKey)

        // Use the saved stdout fd for mirroring to Xcode console
        let savedStdout = dup(STDOUT_FILENO)
        startOutputReader(fd: master, origOut: savedStdout)
        startProcessMonitor(pid: childPid)
    }

    // MARK: - stdin write

    /// Send a command to the pm3 client. In dylib mode this enqueues to the
    /// worker thread; in subprocess mode it writes directly to the child's stdin pipe.
    func write(_ string: String) {
        // Subprocess mode — write raw string to stdin pipe
        if stdinWriteFD >= 0 {
            if let data = string.data(using: .utf8) {
                data.withUnsafeBytes { buf in
                    _ = Darwin.write(stdinWriteFD, buf.baseAddress!, buf.count)
                }
            }
            return
        }
        // Dylib mode — enqueue to worker thread
        guard pm3Console != nil else { return }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cmdQueue.withLock { $0.append(trimmed) }
        cmdSema.signal()
    }

    // MARK: - Terminate

    func terminate() {
        // Kill subprocess if running (simulator path)
        if pid > 0 {
            let pgid = getpgid(pid)
            if pgid > 0 { killpg(pgid, SIGTERM) }
            pid = -1
            UserDefaults.standard.removeObject(forKey: Self.pgidKey)
        }

        // Signal the libpm3 worker thread to exit its loop and call pm3_close().
        shouldQuit.store(true)
        cmdSema.signal()
        pm3Console = nil

        isRunning = false
        processStatus = "Stopped"
        if stdoutReadFD >= 0  { close(stdoutReadFD);  stdoutReadFD  = -1 }
        if stdinWriteFD >= 0  { close(stdinWriteFD);  stdinWriteFD  = -1 }
        if portMasterFD >= 0  { close(portMasterFD);  portMasterFD  = -1 }
        outputContinuation.finish()
    }

    // MARK: - Private

    /// Try to open a PTY pair; fall back to a socketpair if the sandbox blocks posix_openpt.
    /// Returns (master, slave, isPTY). Caller owns both fds.
    private static func openPair() throws -> (master: Int32, slave: Int32, isPTY: Bool) {
        let m = posix_openpt(O_RDWR | O_NOCTTY)
        if m >= 0 {
            _ = grantpt(m)    // may fail in sandbox — non-fatal
            _ = unlockpt(m)
            if let name = ptsname(m) {
                let s = open(name, O_RDWR | O_NOCTTY)
                if s >= 0 { return (m, s, true) }
            }
            close(m)
        }
        // PTY unavailable — bidirectional socketpair (no isatty, but pm3 still works)
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw RunnerError.pipeFailed
        }
        return (fds[0], fds[1], false)
    }

    private func startOutputReader(fd: Int32, origOut: Int32) {
        let continuation = outputContinuation
        Task.detached(priority: .high) {
            let bufSize = 4096
            var buf = [UInt8](repeating: 0, count: bufSize)
            var partial = ""

            while true {
                let n = read(fd, &buf, bufSize)
                guard n > 0 else { break }
                
                if origOut >= 0 {
                    Darwin.write(origOut, buf, n)
                }
                
                let raw = String(bytes: buf[..<n], encoding: .utf8) ?? ""
                // Strip non-color ANSI control sequences (cursor movement, line
                // clearing) that linenoise/readline emits on a PTY-backed stdin.
                // Color sequences (\033[...m) are kept for ANSIParser.
                partial += BinaryRunner.stripControlEscapes(raw)

                var s = partial[...]
                partial = ""

                while !s.isEmpty {
                    if let nl = s.firstIndex(of: "\n") {
                        if let cr = s.firstIndex(of: "\r"), cr < nl {
                            // \r before \n
                            let line = String(s[s.startIndex..<cr])
                            let afterCR = s.index(after: cr)
                            if afterCR == nl {
                                // \r\n — plain newline
                                _ = continuation.yield(line)
                                s = s[s.index(after: nl)...]
                            } else {
                                // Bare \r then more text before \n — overwrite
                                _ = continuation.yield("\r" + line)
                                s = s[afterCR...]
                            }
                        } else {
                            let line = String(s[s.startIndex..<nl])
                            _ = continuation.yield(line)
                            s = s[s.index(after: nl)...]
                        }
                    } else if let cr = s.firstIndex(of: "\r") {
                        let after = s.index(after: cr)
                        if after == s.endIndex {
                            // CR at end — buffer content+CR, wait to see if \r\n arrives
                            partial = String(s)
                            break
                        } else if s[after] == "\n" {
                            // \r\n
                            let line = String(s[s.startIndex..<cr])
                            _ = continuation.yield(line)
                            s = s[s.index(after: after)...]
                        } else {
                            // Bare \r — live overwrite
                            let line = String(s[s.startIndex..<cr])
                            _ = continuation.yield("\r" + line)
                            s = s[after...]
                        }
                    } else {
                        partial = String(s)
                        break
                    }
                }

                // The pm3 prompt ("pm3 -->") has no trailing newline — it stays in
                // partial indefinitely. Detect it and yield now so capture logic fires.
                if !partial.isEmpty && BinaryRunner.looksLikePrompt(partial) {
                    _ = continuation.yield(partial)
                    partial = ""
                }
            }

            if !partial.isEmpty {
                _ = continuation.yield(partial.replacingOccurrences(of: "\r", with: ""))
            }
            continuation.finish()

            await MainActor.run { [weak self] in
                self?.isRunning = false
                self?.processStatus = "Exited"
            }
        }
    }

    // pm3 prompt ends with "pm3 --> " but color codes are embedded between "pm3 " and "-->"
    // so we strip all ANSI before checking.
    private nonisolated static func looksLikePrompt(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: #"\x1B\[[0-9;]*[a-zA-Z]"#, with: "",
                                               options: .regularExpression)
        return stripped.contains("pm3 -->")
    }

    // Keep \033[...m (color) sequences; remove everything else that starts with \033[
    // (\033[K erase-line, \033[0G cursor-col, \033[2J clear-screen, etc.)
    private nonisolated static func stripControlEscapes(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var result = ""
        result.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "\u{1B}" else { result.append(s[i]); i = s.index(after: i); continue }
            let next = s.index(after: i)
            guard next < s.endIndex, s[next] == "[" else {
                // Non-CSI escape — skip the \033, keep rest
                i = next; continue
            }
            // Scan to the final letter (command byte)
            var j = s.index(after: next)
            while j < s.endIndex && !s[j].isLetter { j = s.index(after: j) }
            guard j < s.endIndex else { i = j; continue }
            let cmd = s[j]
            let after = s.index(after: j)
            if cmd == "m" {
                // Color sequence — keep it intact
                result.append(contentsOf: s[i..<after])
            }
            // All other CSI sequences (K, G, J, A, B, C, D, H, f…) — drop
            i = after
        }
        return result
    }

    private func startProcessMonitor(pid: pid_t) {
        Task.detached { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let code = status
            await MainActor.run { [weak self] in
                self?.isRunning = false
                self?.processStatus = "Exited (status \(code))"
            }
        }
    }
}
