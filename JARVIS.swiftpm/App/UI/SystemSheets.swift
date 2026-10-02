import MessageUI
import SwiftUI
import UIKit

/// Apple's own composers and Share Sheet. The user always performs the final
/// send/share step; JARVIS learns the real outcome from the delegate.
struct SystemSheetView: UIViewControllerRepresentable {
    let sheet: Presenter.Sheet
    let presenter: Presenter

    func makeCoordinator() -> Coordinator { Coordinator(presenter: presenter) }

    func makeUIViewController(context: Context) -> UIViewController {
        switch sheet {
        case .message(let recipients, let body):
            let controller = MFMessageComposeViewController()
            controller.recipients = recipients
            controller.body = body
            controller.messageComposeDelegate = context.coordinator
            return controller
        case .mail(let to, let subject, let body):
            let controller = MFMailComposeViewController()
            controller.setToRecipients(to)
            controller.setSubject(subject)
            controller.setMessageBody(body, isHTML: false)
            controller.mailComposeDelegate = context.coordinator
            return controller
        case .share(let items):
            let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
            controller.completionWithItemsHandler = { [weak presenter] _, completed, _, _ in
                Task { @MainActor in presenter?.finish(completed ? .completed : .cancelled) }
            }
            return controller
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate, MFMailComposeViewControllerDelegate {
        let presenter: Presenter
        init(presenter: Presenter) { self.presenter = presenter }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            let outcome: Presenter.Outcome = switch result {
            case .sent: .sent
            case .failed: .failed
            default: .cancelled
            }
            Task { @MainActor in self.presenter.finish(outcome) }
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            let outcome: Presenter.Outcome = switch result {
            case .sent: .sent
            case .saved: .saved
            case .failed: .failed
            default: .cancelled
            }
            Task { @MainActor in self.presenter.finish(outcome) }
        }
    }
}

/// Visible camera capture (photo or video). Never records in the background.
struct CameraPicker: UIViewControllerRepresentable {
    enum Result {
        case image(UIImage)
        case video(URL)
    }

    let completion: (Result?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image", "public.movie"]
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Result?) -> Void
        init(completion: @escaping (Result?) -> Void) { self.completion = completion }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                completion(.video(url))
            } else if let image = info[.originalImage] as? UIImage {
                completion(.image(image))
            } else {
                completion(nil)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completion(nil)
        }
    }
}
