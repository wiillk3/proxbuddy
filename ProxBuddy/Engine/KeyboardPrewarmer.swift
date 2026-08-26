import UIKit

@MainActor
enum KeyboardPrewarmer {
    private static var didPrewarm = false

    static func prewarm() {
        guard !didPrewarm else { return }
        didPrewarm = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else {
                return
            }

            let dummy = UITextField(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
            dummy.autocorrectionType = .no
            dummy.autocapitalizationType = .none
            dummy.spellCheckingType = .no
            dummy.keyboardAppearance = .dark
            dummy.alpha = 0.01
            window.addSubview(dummy)
            dummy.becomeFirstResponder()

            DispatchQueue.main.async {
                dummy.resignFirstResponder()
                dummy.removeFromSuperview()
            }
        }
    }
}
