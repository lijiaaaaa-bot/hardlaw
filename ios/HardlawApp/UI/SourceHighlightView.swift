import SwiftUI

// MARK: - 原文对照

/// 原文对照 — 展示源文件 OCR 全文，并将引用片段以黄色加粗高亮。
/// 顶部显示验证结论：引用是否在原文中逐字存在。
struct SourceHighlightView: View {
    let ocrText: String
    let highlightSnippet: String
    @Environment(\.dismiss) var dismiss

    /// 引用片段是否在原文中找到（忽略大小写与变音符）
    private var isFound: Bool {
        guard !highlightSnippet.isEmpty else { return false }
        return ocrText.range(of: highlightSnippet,
                             options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusBanner

                    if !highlightSnippet.isEmpty {
                        snippetCard
                    }

                    Divider()

                    Text("原文（OCR 提取）")
                        .font(.caption).fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    if ocrText.isEmpty {
                        Text("暂无原文内容")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 24)
                    } else {
                        highlightedBody
                    }
                }
                .padding()
            }
            .navigationTitle("原文对照")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - 验证结论

    private var statusBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: isFound ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isFound ? Color.green : Color.orange)
            Text(isFound ? "此引用已在原文中找到" : "此引用未在原文中找到")
                .font(.subheadline).fontWeight(.semibold)
            Spacer()
        }
        .padding(10)
        .background((isFound ? Color.green : Color.orange).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 引用内容

    private var snippetCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("引用内容", systemImage: "text.quote")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(highlightSnippet)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 高亮正文

    private var highlightedBody: some View {
        Text(highlightedContent)
            .font(.body)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 构造原文：所有匹配片段加粗 + 黄色高亮，其余部分保持原样
    private var highlightedContent: AttributedString {
        var att = AttributedString(ocrText)
        guard !highlightSnippet.isEmpty else { return att }

        var searchStart = ocrText.startIndex
        while searchStart < ocrText.endIndex {
            let searchRange = searchStart..<ocrText.endIndex
            guard let range = ocrText.range(of: highlightSnippet,
                                            options: [.caseInsensitive, .diacriticInsensitive],
                                            range: searchRange) else { break }
            if let lower = AttributedString.Index(range.lowerBound, within: att),
               let upper = AttributedString.Index(range.upperBound, within: att) {
                att[lower..<upper].backgroundColor = Color.yellow.opacity(0.45)
                att[lower..<upper].font = .body.bold()
            }
            searchStart = range.upperBound
        }
        return att
    }
}
