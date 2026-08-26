import SwiftUI
import UIKit

struct TerminalInputBarView: UIViewRepresentable {
    @Binding var externalText: String?
    let onSend: (String) -> Void
    let onHistoryUp: () -> String?
    let onHistoryDown: () -> String?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> NativeTerminalInputBar {
        let bar = NativeTerminalInputBar()
        bar.onSend = onSend
        bar.onHistoryUp = onHistoryUp
        bar.onHistoryDown = onHistoryDown
        context.coordinator.inputBar = bar
        return bar
    }

    func updateUIView(_ uiView: NativeTerminalInputBar, context: Context) {
        uiView.onSend = onSend
        uiView.onHistoryUp = onHistoryUp
        uiView.onHistoryDown = onHistoryDown

        if let ext = externalText {
            uiView.setText(ext)
            uiView.focus()
            DispatchQueue.main.async {
                self.externalText = nil
            }
        }
    }

    final class Coordinator: NSObject {
        var parent: TerminalInputBarView
        weak var inputBar: NativeTerminalInputBar?

        init(_ parent: TerminalInputBarView) {
            self.parent = parent
        }
    }
}

// MARK: - Native UIKit Terminal Input Bar

final class NativeTerminalInputBar: UIView, UITextFieldDelegate {
    var onSend: ((String) -> Void)?
    var onHistoryUp: (() -> String?)?
    var onHistoryDown: (() -> String?)?

    private let promptLabel = UILabel()
    let textField = UITextField()
    private let sendButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)
    private let stackView = UIStackView()

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 48)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = UIColor(white: 0.05, alpha: 1.0)
        isUserInteractionEnabled = true

        stackView.axis = .horizontal
        stackView.spacing = 8
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.isUserInteractionEnabled = true
        addSubview(stackView)

        // Prompt Label
        promptLabel.text = "pm3 -->"
        promptLabel.textColor = UIColor(red: 0.0, green: 0.85, blue: 0.2, alpha: 1.0)
        promptLabel.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
        promptLabel.setContentHuggingPriority(.required, for: .horizontal)
        promptLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        promptLabel.isUserInteractionEnabled = true
        let promptTap = UITapGestureRecognizer(target: self, action: #selector(promptTapped))
        promptLabel.addGestureRecognizer(promptTap)

        // Text Field
        textField.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textField.textColor = .white
        textField.tintColor = UIColor(red: 0.0, green: 0.85, blue: 0.2, alpha: 1.0)
        textField.backgroundColor = .clear
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.spellCheckingType = .no
        textField.smartQuotesType = .no
        textField.smartDashesType = .no
        textField.smartInsertDeleteType = .no
        textField.keyboardType = .asciiCapable
        textField.keyboardAppearance = .dark
        textField.returnKeyType = .send
        textField.delegate = self
        textField.isUserInteractionEnabled = true
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.addTarget(self, action: #selector(textDidChange), for: .editingChanged)

        // Send Button
        sendButton.setImage(UIImage(systemName: "return"), for: .normal)
        sendButton.tintColor = UIColor(red: 0.0, green: 0.85, blue: 0.2, alpha: 1.0)
        sendButton.isHidden = true
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        // Dismiss Button
        dismissButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        dismissButton.tintColor = .gray
        dismissButton.isHidden = true
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)
        dismissButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)

        stackView.addArrangedSubview(promptLabel)
        stackView.addArrangedSubview(textField)
        stackView.addArrangedSubview(sendButton)
        stackView.addArrangedSubview(dismissButton)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])

        // Tap anywhere on the background of the bar to focus
        let barTap = UITapGestureRecognizer(target: self, action: #selector(barTapped))
        barTap.cancelsTouchesInView = false
        addGestureRecognizer(barTap)
    }

    func setText(_ text: String) {
        textField.text = text
        textDidChange()
    }

    func focus() {
        textField.becomeFirstResponder()
    }

    // MARK: - UITextFieldDelegate

    func textFieldDidBeginEditing(_ textField: UITextField) {
        dismissButton.isHidden = false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        dismissButton.isHidden = true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return true
    }

    // MARK: - Actions

    @objc private func barTapped() {
        if !textField.isFirstResponder {
            textField.becomeFirstResponder()
        }
    }

    @objc private func textDidChange() {
        let hasText = !(textField.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        sendButton.isHidden = !hasText
    }

    @objc private func sendTapped() {
        submit()
    }

    @objc private func dismissTapped() {
        textField.resignFirstResponder()
    }

    @objc private func promptTapped() {
        if textField.isFirstResponder {
            historyUpTapped()
        } else {
            textField.becomeFirstResponder()
        }
    }

    @objc private func historyUpTapped() {
        if let cmd = onHistoryUp?() {
            textField.text = cmd
            textDidChange()
        }
    }

    @objc private func historyDownTapped() {
        if let cmd = onHistoryDown?() {
            textField.text = cmd
            textDidChange()
        }
    }

    private func submit() {
        guard let raw = textField.text, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        textField.text = ""
        textDidChange()
        onSend?(raw)
    }
}
