import Foundation
import UniformTypeIdentifiers

// MARK: - Excel Export (CSV format)

/// Generates a CSV file of the 7-column evidence catalog.
/// Compatible with Excel, WPS, Numbers — uses UTF-8 BOM so Chinese headers render correctly.
public enum ExcelExport {

    // MARK: - 目录导出

    /// Export the evidence catalog as a CSV file (案由/申请人/被申请人/日期 + 七列目录).
    public static func exportCatalog(_ caseFile: CaseFile) -> URL? {
        var rows: [[String]] = []
        rows.append(contentsOf: caseInfoRows(caseFile))
        rows.append(contentsOf: catalogRows(caseFile))

        let fileName = "\(caseFile.caseName.isEmpty ? "证据目录" : caseFile.caseName)_证据目录.csv"
        return writeCSV(rows, fileName: fileName)
    }

    // MARK: - 缺口报告导出

    /// Export the gap report as CSV (案由/申请人/被申请人/日期 + 待核实清单).
    public static func exportGaps(_ caseFile: CaseFile) -> URL? {
        var rows: [[String]] = []
        rows.append(contentsOf: caseInfoRows(caseFile))
        rows.append(contentsOf: gapRows(caseFile))

        let fileName = "\(caseFile.caseName.isEmpty ? "待核实清单" : caseFile.caseName)_待核实清单.csv"
        return writeCSV(rows, fileName: fileName)
    }

    // MARK: - 合并报告导出

    /// Export BOTH the 7-column catalog AND the gap report into a single CSV file,
    /// separated by a blank row and a "--- 待核实清单 ---" section header.
    /// Structure:
    ///   案由/申请人/被申请人/日期  (案件信息头)
    ///   (空行)
    ///   组别/编号/…/核实状态       (七列证据目录)
    ///   (空行)
    ///   --- 待核实清单 ---
    ///   严重度/缺口描述/补证建议/关联请求/状态  (缺口报告)
    public static func exportFullReport(_ caseFile: CaseFile) -> URL? {
        var rows: [[String]] = []

        // 1. 案件信息头
        rows.append(contentsOf: caseInfoRows(caseFile))

        // 2. 七列证据目录
        rows.append(contentsOf: catalogRows(caseFile))

        // 3. 空行 + 待核实清单分隔头
        rows.append([""])
        rows.append(["--- 待核实清单 ---"])
        rows.append(contentsOf: gapRows(caseFile))

        let fileName = "\(caseFile.caseName.isEmpty ? "证据目录" : caseFile.caseName)_证据目录与待核实清单.csv"
        return writeCSV(rows, fileName: fileName)
    }

    // MARK: - 行构造（私有）

    /// 案件信息头：案由、申请人、被申请人、日期（后接空行分隔）。
    private static func caseInfoRows(_ caseFile: CaseFile) -> [[String]] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        formatter.locale = Locale(identifier: "zh_CN")
        let dateString = formatter.string(from: caseFile.createdAt)

        return [
            ["案由", caseFile.caseName],
            ["申请人", caseFile.applicant],
            ["被申请人", caseFile.respondent],
            ["日期", dateString],
            [""],
        ]
    }

    /// 七列证据目录（含表头）。
    private static func catalogRows(_ caseFile: CaseFile) -> [[String]] {
        var rows: [[String]] = []
        rows.append(["组别", "编号", "证据名称", "原件/复印件", "页码", "证明内容", "证明目的", "核实状态"])

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
        return rows
    }

    /// 待核实清单（含表头）。
    private static func gapRows(_ caseFile: CaseFile) -> [[String]] {
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
        return rows
    }

    // MARK: - 写入（私有）

    /// Build CSV with UTF-8 BOM (for Excel/WPS recognition) and write to a temp file.
    private static func writeCSV(_ rows: [[String]], fileName: String) -> URL? {
        var csv = "\u{FEFF}" // BOM for Excel UTF-8 recognition
        for row in rows {
            csv += row.map { escapeCSV($0) }.joined(separator: ",") + "\n"
        }

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
