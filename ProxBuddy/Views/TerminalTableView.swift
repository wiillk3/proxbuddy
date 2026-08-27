import SwiftUI
import UIKit
import Combine

struct TerminalTableView: UIViewRepresentable {
    @ObservedObject var engine: TerminalEngine
    var showTimestamps: Bool
    @Binding var isAutoScrolling: Bool
    var onHintTap: (String) -> Void
    var onHintLongPress: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITableView {
        let tableView = UITableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive
        tableView.showsVerticalScrollIndicator = true
        tableView.indicatorStyle = .white
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 22
        tableView.contentInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        tableView.register(TerminalLineCell.self, forCellReuseIdentifier: TerminalLineCell.reuseIdentifier)
        tableView.delegate = context.coordinator

        context.coordinator.setupDataSource(tableView: tableView)
        context.coordinator.bind(engine: engine)

        return tableView
    }

    func updateUIView(_ uiView: UITableView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.currentShowTimestamps != showTimestamps {
            context.coordinator.currentShowTimestamps = showTimestamps
            context.coordinator.reloadCurrentData()
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITableViewDelegate {
        var parent: TerminalTableView
        var tableView: UITableView?
        var dataSource: UITableViewDiffableDataSource<Int, UUID>?
        private var lineMap: [UUID: TerminalLine] = [:]
        private var appliedIDs: [UUID] = []
        private var cancellable: AnyCancellable?
        var currentShowTimestamps: Bool = false
        private var pendingFlush: DispatchWorkItem?
        private var pendingLines: [TerminalLine]?

        init(parent: TerminalTableView) {
            self.parent = parent
            self.currentShowTimestamps = parent.showTimestamps
        }

        func setupDataSource(tableView: UITableView) {
            self.tableView = tableView
            dataSource = UITableViewDiffableDataSource<Int, UUID>(tableView: tableView) { [weak self] (tv, indexPath, lineID) -> UITableViewCell? in
                guard let self = self,
                      let cell = tv.dequeueReusableCell(withIdentifier: TerminalLineCell.reuseIdentifier, for: indexPath) as? TerminalLineCell,
                      let line = self.lineMap[lineID] else {
                    return UITableViewCell()
                }

                cell.configure(
                    line: line,
                    showTimestamp: self.currentShowTimestamps,
                    onHintTap: { [weak self] cmd in
                        self?.parent.onHintTap(cmd)
                    },
                    onHintLongPress: { [weak self] cmd in
                        self?.parent.onHintLongPress(cmd)
                    }
                )
                return cell
            }
            dataSource?.defaultRowAnimation = .none
        }

        func bind(engine: TerminalEngine) {
            cancellable = engine.$lines
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newLines in
                    self?.scheduleApply(lines: newLines)
                }
        }

        private func scheduleApply(lines: [TerminalLine]) {
            pendingLines = lines
            guard pendingFlush == nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingFlush = nil
                guard let latest = self.pendingLines else { return }
                self.pendingLines = nil
                self.applyNow(lines: latest)
            }
            pendingFlush = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: workItem)
        }

        private func applyNow(lines: [TerminalLine]) {
            guard let ds = dataSource else { return }

            var map: [UUID: TerminalLine] = [:]
            var ids: [UUID] = []
            ids.reserveCapacity(lines.count)
            map.reserveCapacity(lines.count)
            for line in lines {
                map[line.id] = line
                ids.append(line.id)
            }
            lineMap = map

            if ids == appliedIDs { return }

            let isAtBottom = parent.isAutoScrolling
            let snapshot: NSDiffableDataSourceSnapshot<Int, UUID>
            if appliedIDs.isEmpty || ids.isEmpty {
                var full = NSDiffableDataSourceSnapshot<Int, UUID>()
                full.appendSections([0])
                full.appendItems(ids, toSection: 0)
                snapshot = full
            } else {
                var delta = ds.snapshot()
                let newSet = Set(ids)
                let removed = appliedIDs.filter { !newSet.contains($0) }
                if !removed.isEmpty { delta.deleteItems(removed) }
                let appliedSet = Set(appliedIDs)
                let added = ids.filter { !appliedSet.contains($0) }
                if !added.isEmpty { delta.appendItems(added, toSection: 0) }
                snapshot = delta
            }

            appliedIDs = ids
            ds.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self, isAtBottom, !ids.isEmpty else { return }
                let ip = IndexPath(row: ids.count - 1, section: 0)
                self.tableView?.scrollToRow(at: ip, at: .bottom, animated: false)
            }
        }

        func reloadCurrentData() {
            guard let ds = dataSource else { return }
            var snapshot = ds.snapshot()
            if #available(iOS 15.0, *) {
                snapshot.reconfigureItems(snapshot.itemIdentifiers)
            } else {
                snapshot.reloadItems(snapshot.itemIdentifiers)
            }
            ds.apply(snapshot, animatingDifferences: false)
        }

        func scrollToBottom() {
            guard let ds = dataSource, let tv = tableView else { return }
            let count = ds.snapshot().itemIdentifiers.count
            guard count > 0 else { return }
            let ip = IndexPath(row: count - 1, section: 0)
            tv.scrollToRow(at: ip, at: .bottom, animated: true)
        }

        // MARK: - UIScrollViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let offset = scrollView.contentOffset.y
            let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
            let isNearBottom = (maxOffset - offset) < 60

            if parent.isAutoScrolling != isNearBottom {
                DispatchQueue.main.async {
                    self.parent.isAutoScrolling = isNearBottom
                }
            }
        }
    }
}

// MARK: - Native Terminal Cell

final class TerminalLineCell: UITableViewCell, UIContextMenuInteractionDelegate {
    static let reuseIdentifier = "TerminalLineCell"

    private let containerStack = UIStackView()
    private let textStack = UIStackView()
    private let timestampLabel = UILabel()
    private let contentLabel = UILabel()
    private let hintButton = UIButton(type: .system)

    private var currentLine: TerminalLine?
    private var onHintTapCallback: ((String) -> Void)?
    private var onHintLongPressCallback: ((String) -> Void)?

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        containerStack.axis = .vertical
        containerStack.spacing = 3
        containerStack.alignment = .leading
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(containerStack)

        textStack.axis = .horizontal
        textStack.spacing = 6
        textStack.alignment = .top
        textStack.translatesAutoresizingMaskIntoConstraints = false

        timestampLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        timestampLabel.textColor = .gray
        timestampLabel.setContentHuggingPriority(.required, for: .horizontal)
        timestampLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        contentLabel.numberOfLines = 0
        contentLabel.lineBreakMode = .byWordWrapping
        contentLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        textStack.addArrangedSubview(timestampLabel)
        textStack.addArrangedSubview(contentLabel)

        // Hint Button Setup
        hintButton.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        hintButton.setTitleColor(UIColor(red: 0.0, green: 0.85, blue: 0.2, alpha: 1.0), for: .normal)
        hintButton.backgroundColor = UIColor(red: 0.0, green: 0.85, blue: 0.2, alpha: 0.15)
        hintButton.layer.cornerRadius = 6
        hintButton.layer.borderWidth = 1
        hintButton.layer.borderColor = UIColor(red: 0.0, green: 0.85, blue: 0.2, alpha: 0.4).cgColor
        hintButton.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        hintButton.addTarget(self, action: #selector(hintButtonTapped), for: .touchUpInside)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(hintButtonLongPressed(_:)))
        longPress.minimumPressDuration = 0.5
        hintButton.addGestureRecognizer(longPress)

        containerStack.addArrangedSubview(textStack)
        containerStack.addArrangedSubview(hintButton)

        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1),
            containerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -1),
            containerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            containerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            textStack.widthAnchor.constraint(equalTo: containerStack.widthAnchor)
        ])

        let interaction = UIContextMenuInteraction(delegate: self)
        addInteraction(interaction)
    }

    func configure(line: TerminalLine,
                   showTimestamp: Bool,
                   onHintTap: @escaping (String) -> Void,
                   onHintLongPress: @escaping (String) -> Void) {
        self.currentLine = line
        self.onHintTapCallback = onHintTap
        self.onHintLongPressCallback = onHintLongPress

        timestampLabel.isHidden = !showTimestamp
        if showTimestamp {
            timestampLabel.text = Self.timeFormatter.string(from: line.timestamp)
        }

        contentLabel.attributedText = line.nsAttributedText

        if let hint = line.hint {
            hintButton.isHidden = false
            hintButton.setTitle("▶ \(hint)", for: .normal)
        } else {
            hintButton.isHidden = true
        }
    }

    @objc private func hintButtonTapped() {
        guard let hint = currentLine?.hint else { return }
        onHintTapCallback?(hint)
    }

    @objc private func hintButtonLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let hint = currentLine?.hint else { return }
        onHintLongPressCallback?(hint)
    }

    // MARK: - UIContextMenuInteractionDelegate

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let raw = currentLine?.raw else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copyRaw = UIAction(title: "Copy Line", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = raw
            }

            let clean = ANSIParser.strip(raw)
            let copyClean = UIAction(title: "Copy Clean Text", image: UIImage(systemName: "text.quote")) { _ in
                UIPasteboard.general.string = clean
            }

            return UIMenu(title: "", children: [copyClean, copyRaw])
        }
    }
}
