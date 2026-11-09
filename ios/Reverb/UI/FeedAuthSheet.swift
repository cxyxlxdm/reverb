import SwiftUI

/// 私有订阅源的登录框:feed 返回 401 时由发现页 / 频道详情页弹出。
///
/// 与 macOS `UI/FeedAuthSheet.swift`、Android `ui/components/FeedAuthDialog.kt` 同一组文案、
/// 同一条校验:用户名非空才可提交(口令可以为空)。凭据只随请求发给源自己,见 `FeedAuthStore`。
struct FeedAuthSheet: View {
    let feedUrl: String
    /// true = 本机已存过这个源的凭据,但仍是 401 —— 显示错误行、预填用户名。
    let failed: Bool
    let initialUsername: String
    var onSubmit: (String, String) -> Void
    var onCancel: () -> Void

    @State private var username: String
    @State private var password = ""

    init(feedUrl: String, failed: Bool, initialUsername: String,
         onSubmit: @escaping (String, String) -> Void,
         onCancel: @escaping () -> Void) {
        _username = State(initialValue: initialUsername)
        self.feedUrl = feedUrl
        self.failed = failed
        self.initialUsername = initialUsername
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    /// 输入框里只给主机:「https://user@host/feed.xml?token=…」整串既不必要也可能带 token。
    private var host: String {
        URLComponents(string: feedUrl)?.host ?? feedUrl
    }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit(username.trimmingCharacters(in: .whitespacesAndNewlines), password)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(String(format: NSLocalizedString("「%@」要求先验证身份才能读取。凭据只保存在这台设备上，不会写进备份，也不会随订阅导出。", comment: "私有订阅源登录框说明"), host))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if failed {
                    Section {
                        Text(NSLocalizedString("这对用户名和密码没有通过，再核对一下。", comment: "私有订阅源登录失败"))
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    TextField(NSLocalizedString("用户名", comment: ""), text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                    SecureField(NSLocalizedString("密码", comment: ""), text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                }
            }
            .navigationTitle(NSLocalizedString("需要用户名和密码", comment: "私有订阅源登录框标题"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存并重试", comment: "")) { submit() }
                        .disabled(!canSubmit)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
