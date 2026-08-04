import Foundation
import UniformTypeIdentifiers

// MARK: - Excel Export (CSV format)

/// Generates a CSV file of the 7-column evidence catalog.
/// Compatible with Excel, WPS, Numbers — uses GB2312-friendly encoding.
public enum ExcelExport {

    /// Export the evidence catalog as a CSV file.
    public static func exportCatalog(_ caseFile: CaseFile) -> URL? {
        var rows: [[String]] = []

        // Header
        rows.append(["组别", "编号", "证据名称", "原件/复印件", "页码", "证明内容", "证明目的", "核实状态"])

        // Data rows
        for item in caseFile.evidenceItems.sorted(by: { $0.number < $1.number }) {
            rows.append([
                item.group,
                "\(item.number)",
                item.name,
                item.isOriginal ? "原件" : "复印件",
                "\(item.pageCount)",
                item.proofContentState.displayValue ?? "",
                item.proofPurposeState.displayValue ?? "",
                verificationLabel(item),
            ])
        }

        // Build CSV
        var csv = "\u{FEFF}" // BOM for Excel UTF-8 recognition
        for row in rows {
            csv += row.map { escapeCSV($0) }.joined(separator: ",") + "\n"
        }

        // Write to temp file
        let fileName = "\(caseFile.caseName.isEmpty ? "证据目录" : caseFile.caseName)_证据目录.csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Export the gap report as CSV.
    public static func exportGaps(_ caseFile: CaseFile) -> URL? {
        var rows: [[String]] = []
        rows.append(["严重度", "缺口描述", "补证建议", "关联请求", "状态"])

        for gap in caseFile.gaps {
            rows.append([
                gap.severity.rawValue,
                gap.description,
                gap.suggestedRemedy,
                gap.relatedClaim,
                gap.isResolved ? "已解决" : "待处理",
            ])
        }

        var csv = "\u{FEFF}"
        for row in rows {
            csv += row.map { escapeCSV($0) }.joined(separator: ",") + "\n"
        }

        let fileName = "\(caseFile.caseName.isEmpty ? "待核实清单" : caseFile.caseName)_待核实清单.csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private static func verificationLabel(_ item: EvidenceItem) -> String {
        if item.humanReviewed { return "人工已确认" }
        if item.proofContentState.stale { return "待更新" }
        if item.proofContentState.status == .machineDraft { return "AI草稿" }
        return "未核实"
    }

    private static func escapeCSV(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }
}
