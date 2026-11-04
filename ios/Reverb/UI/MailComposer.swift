import SwiftUI
import MessageUI

/// 系统邮件起草器的 SwiftUI 包装。「发送日志到开发者邮箱」用:正文是用户描述问题的模板,
/// 附件是日志文件。**不自己调用 `dismiss`** —— 收尾交给 `onFinish` 把 SwiftUI 的 sheet 关掉,
/// 否则 SwiftUI 的呈现状态还停在 true,再点一次会打不开。
struct MailComposer: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    var attachment: (name: String, data: Data)?
    var onFinish: () -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([recipient])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        if let attachment {
            vc.addAttachmentData(attachment.data, mimeType: "text/plain", fileName: attachment.name)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            if let error { Log.e("Mail", "日志邮件未发出", error: error) }
            onFinish()
        }
    }
}
