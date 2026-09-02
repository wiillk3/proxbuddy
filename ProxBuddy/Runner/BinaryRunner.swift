import Foundation

// libpm3 C ABI
typealias PM3OpenFunc        = @convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?
typealias PM3ConsoleFunc     = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Bool, Bool) -> Int32
typealias PM3CloseFunc       = @convention(c) (OpaquePointer?) -> Void
typealias PM3VoidFunc        = @convention(c) () -> Void

/// Return codes from Iceman `include/pm3_cmd.h`. `quit` / `exit` return `quit`
/// rather than calling libc `exit()`; `fatal` is how the standalone client
/// leaves the prompt on an unrecoverable error. Either must end the in-process
/// session without terminating ProxBuddy.
enum PM3ClientStatus {
    static let success: Int32 = 0
    static let fatal: Int32 = -99   // PM3_EFATAL
    static let quit: Int32 = -100   // PM3_SQUIT

    static func endsSession(_ rc: Int32) -> Bool {
        rc == fatal || rc == quit
    }
}

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
    case tcpOpenFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:    return "pm3client binary not found in app bundle"
        case .pipeFailed:        return "Failed to create stdio pipes"
        case .spawnFailed(let e): return "spawn failed: errno \(e)"
        case .dlopenFailed(let s): return "dlopen failed: \(s)"
        case .dlsymFailed(let s): return "dlsym failed: \(s)"
        case .tcpOpenFailed(let s): return "pm3 could not open \(s)"
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
    // Serial-port pair created during BLE launch — master is kept for BLETransport relay
    private(set) var portMasterFD: Int32 = -1

    // libpm3 command pump
    fileprivate var pm3Console: PM3ConsoleFunc?
    fileprivate let cmdQueue   = MutexBox<[String]>([])
    fileprivate let cmdSema    = DispatchSemaphore(value: 0)
    /// Replaced on every launch so a prior `terminate()` cannot kill the new worker.
    fileprivate var shouldQuit = AtomicBool()
    private var workerEpoch = 0
    private var previousWorkerExit: DispatchSemaphore?

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

    /// BLE: local tcp: loopback. `onLocalAccept` attaches BLETransport to the accepted fd.
    func launch(onLocalAccept: (@MainActor (Int32) -> Void)? = nil) async throws {
        try await launchLibPM3(remoteTCP: nil, onLocalAccept: onLocalAccept)
    }

    /// BWM WiFi: libpm3 opens `tcp:host:port` itself (same as `pm3 -p tcp:…`).
    func launch(tcpHost: String, tcpPort: UInt16) async throws {
        try await launchLibPM3(remoteTCP: "tcp:\(tcpHost):\(tcpPort)", onLocalAccept: nil)
    }

    private func bundledClientURL() throws -> URL {
        guard let binaryURL = PM3ClientVersion.bundledDylibURL() else {
            throw RunnerError.binaryNotFound
        }
        return binaryURL
    }

    /// LIBPM3 mode — dlopen the dylib, resolve pm3_open/console/close, then run a
    /// dedicated 8MB-stack thread. `remoteTCP` is a `tcp:host:port` string for BWM
    /// WiFi; nil uses a localhost relay socket for BLE.
    private func launchLibPM3(remoteTCP: String?, onLocalAccept: (@MainActor (Int32) -> Void)?) async throws {
        let binaryURL = try bundledClientURL()
        let binaryPath = binaryURL.path
        await reapOrphan()
        await waitForPreviousWorker()
        cmdQueue.withLock { $0.removeAll() }

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

        // BLE: local loopback so BLETransport can relay. WiFi: libpm3 dials the BWM TCP server.
        let serverFD: Int32?
        let connectionString: String
        if let remote = remoteTCP {
            serverFD = nil
            connectionString = remote
            portMasterFD = -1
        } else {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                close(stdoutMaster); close(stdoutSlave)
                throw RunnerError.pipeFailed
            }
            var opt: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(0).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            var bindAddr = sockaddr()
            memcpy(&bindAddr, &addr, MemoryLayout<sockaddr_in>.size)

            guard Darwin.bind(fd, &bindAddr, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                close(stdoutMaster); close(stdoutSlave); close(fd)
                throw RunnerError.pipeFailed
            }
            guard Darwin.listen(fd, 1) == 0 else {
                close(stdoutMaster); close(stdoutSlave); close(fd)
                throw RunnerError.pipeFailed
            }

            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            var sin = sockaddr_in()
            withUnsafeMutablePointer(to: &sin) { sinPtr in
                sinPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    _ = getsockname(fd, sockaddrPtr, &len)
                }
            }
            let localPort = UInt16(bigEndian: sin.sin_port)
            serverFD = fd
            connectionString = "tcp:127.0.0.1:\(localPort)"
        }

        guard let openSym    = dlsym(handle, "pm3_open"),
              let consoleSym = dlsym(handle, "pm3_console"),
              let closeSym   = dlsym(handle, "pm3_close") else {
            let err = String(cString: dlerror())
            dlclose(handle)
            close(stdoutMaster); close(stdoutSlave)
            if let serverFD { close(serverFD) }
            throw RunnerError.dlsymFailed(err)
        }
        let pm3Open    = unsafeBitCast(openSym,    to: PM3OpenFunc.self)
        let pm3Console = unsafeBitCast(consoleSym, to: PM3ConsoleFunc.self)
        let pm3Close   = unsafeBitCast(closeSym,   to: PM3CloseFunc.self)
        // Optional: compiled out of older LIBPM3 builds; present after ios-pm3-startup-banner.patch.
        let pm3ShowBanner: PM3VoidFunc? = dlsym(handle, "pm3_show_banner").map {
            unsafeBitCast($0, to: PM3VoidFunc.self)
        }
        let pm3VersionShort: PM3VoidFunc? = dlsym(handle, "pm3_version_short").map {
            unsafeBitCast($0, to: PM3VoidFunc.self)
        }

        let savedStdout = dup(STDOUT_FILENO)

        self.stdoutReadFD  = stdoutMaster
        self.processStatus = remoteTCP == nil ? "Running (libpm3)" : "Running (tcp)"

        startOutputReader(fd: stdoutMaster, origOut: savedStdout)

        dup2(stdoutSlave, STDOUT_FILENO)
        close(stdoutSlave)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        setenv("HOME", docs.path, 1)
        setenv("TERM", "xterm-256color", 1)
        setenv("PM3HOME", pm3Home, 1)

        self.pm3Console = pm3Console
        workerEpoch += 1
        let epoch = workerEpoch
        let quit = AtomicBool()
        shouldQuit = quit
        let exitSema = DispatchSemaphore(value: 0)
        previousWorkerExit = exitSema
        let cmdQueue    = self.cmdQueue
        let cmdSema     = self.cmdSema
        let acceptHook  = onLocalAccept
        let wrappedExit: @Sendable () -> Void = { [weak self] in
            exitSema.signal()
            Task { @MainActor in
                guard let self, self.workerEpoch == epoch else { return }
                self.isRunning = false
                self.processStatus = "Exited"
            }
        }

        if let serverFD {
            // BLE: resume once the loopback accept completes so the session can
            // attach BLETransport. pm3_open/TestProxmark runs on the C thread.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Thread { [weak self] in
                    var clientAddr = sockaddr()
                    var clientAddrLen = socklen_t(MemoryLayout<sockaddr>.size)
                    let fd = Darwin.accept(serverFD, &clientAddr, &clientAddrLen)
                    close(serverFD)
                    Task { @MainActor in
                        if fd >= 0 {
                            self?.portMasterFD = fd
                            acceptHook?(fd)
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: RunnerError.pipeFailed)
                        }
                    }
                }.start()

                Self.startPM3Thread(
                    pm3Open: pm3Open,
                    pm3Console: pm3Console,
                    pm3Close: pm3Close,
                    pm3ShowBanner: pm3ShowBanner,
                    pm3VersionShort: pm3VersionShort,
                    connectionString: connectionString,
                    savedStdout: savedStdout,
                    cmdQueue: cmdQueue,
                    cmdSema: cmdSema,
                    shouldQuit: quit,
                    onExit: wrappedExit
                )
            }
        } else {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let settled = AtomicBool()
                Self.startPM3Thread(
                    pm3Open: pm3Open,
                    pm3Console: pm3Console,
                    pm3Close: pm3Close,
                    pm3ShowBanner: pm3ShowBanner,
                    pm3VersionShort: pm3VersionShort,
                    connectionString: connectionString,
                    savedStdout: savedStdout,
                    cmdQueue: cmdQueue,
                    cmdSema: cmdSema,
                    shouldQuit: quit,
                    onOpened: {
                        guard !settled.load() else { return }
                        settled.store(true)
                        continuation.resume()
                    },
                    onOpenFailed: {
                        guard !settled.load() else { return }
                        settled.store(true)
                        continuation.resume(throwing: RunnerError.tcpOpenFailed(connectionString))
                    },
                    onExit: wrappedExit
                )
            }
        }
        isRunning = true
    }

    private func waitForPreviousWorker() async {
        guard let prev = previousWorkerExit else { return }
        previousWorkerExit = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                prev.wait()
                continuation.resume()
            }
        }
    }

    /// C client thread — `pm3_open` / console loop / `pm3_close`.
    private static func startPM3Thread(
        pm3Open: PM3OpenFunc,
        pm3Console: PM3ConsoleFunc,
        pm3Close: PM3CloseFunc,
        pm3ShowBanner: PM3VoidFunc?,
        pm3VersionShort: PM3VoidFunc?,
        connectionString: String,
        savedStdout: Int32,
        cmdQueue: MutexBox<[String]>,
        cmdSema: DispatchSemaphore,
        shouldQuit: AtomicBool,
        onOpened: (() -> Void)? = nil,
        onOpenFailed: (() -> Void)? = nil,
        onExit: @escaping @Sendable () -> Void
    ) {
        let thread = Thread {
            let dev = pm3Open(connectionString)
            if dev == nil {
                close(STDOUT_FILENO)
                if savedStdout >= 0 { dup2(savedStdout, STDOUT_FILENO); close(savedStdout) }
                onOpenFailed?()
                onExit()
                return
            }
            onOpened?()

            // Same sequence as the desktop interactive client: ASCII banner +
            // short hw/client/bootrom/OS block, then the prompt.
            pm3ShowBanner?()
            pm3VersionShort?()

            fputs("pm3 --> ", stdout)
            fflush(stdout)

            while !shouldQuit.load() {
                cmdSema.wait()
                if shouldQuit.load() { break }
                let cmd: String? = cmdQueue.withLock { q in
                    q.isEmpty ? nil : q.removeFirst()
                }
                guard let cmd else { continue }
                let rc = cmd.withCString { pm3Console(dev, $0, false, false) }
                if PM3ClientStatus.endsSession(rc) {
                    let msg = rc == PM3ClientStatus.quit
                        ? "\n[=] session ended (quit). The app is still running — reconnect from the device screen.\n"
                        : "\n[!] client session ended. The app is still running — reconnect from the device screen.\n"
                    fputs(msg, stdout)
                    fflush(stdout)
                    break
                }
                fputs("\npm3 --> ", stdout)
                fflush(stdout)
            }
            pm3Close(dev)

            close(STDOUT_FILENO)
            if savedStdout >= 0 { dup2(savedStdout, STDOUT_FILENO); close(savedStdout) }
            onExit()
        }
        thread.name = "pm3-libpm3"
        thread.stackSize = 8 * 1024 * 1024
        thread.start()
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
            var splitter = OutputLineSplitter()
            var utf8Remainder: [UInt8] = []

            while true {
                let n = read(fd, &buf, bufSize)
                guard n > 0 else { break }

                if origOut >= 0 {
                    Darwin.write(origOut, buf, n)
                }

                utf8Remainder.append(contentsOf: buf[..<n])
                let raw = BinaryRunner.decodeUTF8(&utf8Remainder)
                for line in splitter.push(raw) {
                    _ = continuation.yield(line)
                }
            }

            for line in splitter.finish() {
                _ = continuation.yield(line)
            }
            continuation.finish()

            await MainActor.run { [weak self] in
                self?.isRunning = false
                self?.processStatus = "Exited"
            }
        }
    }

    /// Decode as much UTF-8 as possible; keep a short incomplete sequence for the next read.
    /// Mix-mode bars are 3-byte block glyphs, so a 4096-byte cut can otherwise drop a whole chunk.
    nonisolated static func decodeUTF8(_ bytes: inout [UInt8]) -> String {
        if bytes.isEmpty { return "" }
        if let s = String(bytes: bytes, encoding: .utf8) {
            bytes.removeAll(keepingCapacity: true)
            return s
        }
        let maxHold = min(3, bytes.count)
        for hold in 1...maxHold {
            let cut = bytes.count - hold
            if let s = String(bytes: bytes[..<cut], encoding: .utf8) {
                bytes.removeFirst(cut)
                return s
            }
        }
        bytes.removeAll(keepingCapacity: true)
        return ""
    }

    // pm3 prompt ends with "pm3 --> " but color codes are embedded between "pm3 " and "-->"
    // so we strip all ANSI before checking.
    fileprivate nonisolated static func looksLikePrompt(_ s: String) -> Bool {
        ANSIParser.isClientPrompt(s)
    }

    // Keep \033[...m (color) sequences; remove everything else that starts with \033[
    // (\033[K erase-line, \033[0G cursor-col, \033[2J clear-screen, etc.)
    fileprivate nonisolated static func stripControlEscapes(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var result = ""
        result.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\u{8}" { i = s.index(after: i); continue }
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

/// Turns pm3 stdout into committed lines and `\r`-prefixed live overwrites.
///
/// Carriage return means "the text after this `\r` replaces the current line"
/// (`hf tune --mix` bars, `hf search` INPLACE spinners). Text before `\r` was
/// overwritten and must not be shown. An in-progress live line is flushed so
/// the UI can paint it before the next delimiter arrives.
struct OutputLineSplitter {
    private var partial = ""
    private var live = false

    mutating func push(_ raw: String) -> [String] {
        guard !raw.isEmpty || !partial.isEmpty else { return [] }
        let stripped = BinaryRunner.stripControlEscapes(raw)
            .replacingOccurrences(of: "\u{8}", with: "")
        // Swift treats CRLF as one Character, so `\r\n` would never match `"\n"` / `"\r"`.
        var s = (partial + stripped).replacingOccurrences(of: "\r\n", with: "\n")[...]
        partial = ""
        var out: [String] = []

        while !s.isEmpty {
            if let nl = s.firstIndex(of: "\n") {
                var chunk = s[s.startIndex..<nl]
                if chunk.hasSuffix("\r") {
                    chunk = chunk.dropLast()
                }
                out.append(Self.lastCRSegment(chunk))
                live = false
                s = s[s.index(after: nl)...]
            } else if let cr = s.firstIndex(of: "\r") {
                let after = s.index(after: cr)
                if after == s.endIndex {
                    // Might be `\r\n` arriving next — wait.
                    partial = String(s)
                    break
                }
                // Bare `\r`: subsequent text is the new live line.
                s = s[after...]
                live = true
            } else {
                partial = String(s)
                break
            }
        }

        if !partial.isEmpty && BinaryRunner.looksLikePrompt(partial) {
            out.append(partial)
            partial = ""
            live = false
        } else if live && !partial.isEmpty && !partial.hasSuffix("\r") {
            out.append("\r" + partial)
        }
        return out
    }

    mutating func finish() -> [String] {
        let leftover = partial.replacingOccurrences(of: "\r", with: "")
        partial = ""
        live = false
        return leftover.isEmpty ? [] : [leftover]
    }

    private static func lastCRSegment(_ s: Substring) -> String {
        if let cr = s.lastIndex(of: "\r") {
            return String(s[s.index(after: cr)...])
        }
        return String(s)
    }
}

