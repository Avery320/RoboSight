import SwiftUI

/// RoboSight Settings 共用的 Section 容器。
struct SettingsSection<Content: View>: View {
    private let title: LocalizedStringKey
    private let footer: LocalizedStringKey?
    private let content: Content

    init(
        _ title: LocalizedStringKey,
        footer: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            Text(title)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }
}

/// Settings 中共用的唯讀名稱／值欄位。
struct SettingsValueRow: View {
    private let title: LocalizedStringKey
    private let value: String

    init(_ title: LocalizedStringKey, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(title)
        }
    }
}

/// Settings 中共用的一般或錯誤訊息。
struct SettingsStatusText: View {
    private let message: String
    private let isError: Bool

    init(_ message: String, isError: Bool = false) {
        self.message = message
        self.isError = isError
    }

    var body: some View {
        Text(message)
            .foregroundStyle(isError ? Color.red : Color.secondary)
    }
}
