import SwiftUI
import UIKit

/// Keep UIKit's interactive edge transition when the chat supplies its own header.
struct ConversationBackGesture: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.installIfVisible() }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.restore() }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var installedRecognizer: UIGestureRecognizer?
        private weak var previousDelegate: (any UIGestureRecognizerDelegate)?
        private var isVisible = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isVisible = true
            installIfVisible()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            isVisible = false
            restore()
        }

        func installIfVisible() {
            guard isVisible, let navigationController,
                  navigationController.viewControllers.count > 1,
                  let recognizer = navigationController.interactivePopGestureRecognizer else { return }
            if installedRecognizer !== recognizer || recognizer.delegate !== self {
                restore()
                previousDelegate = recognizer.delegate
                installedRecognizer = recognizer
                recognizer.delegate = self
            }
            recognizer.isEnabled = true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isVisible, view.window != nil, let navigationController else { return false }
            return navigationController.viewControllers.count > 1 && navigationController.transitionCoordinator == nil
        }

        func restore() {
            if let recognizer = installedRecognizer, recognizer.delegate === self {
                recognizer.delegate = previousDelegate
            }
            installedRecognizer = nil
            previousDelegate = nil
        }
    }
}
