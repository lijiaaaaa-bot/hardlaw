import Foundation
import os
import TabularData
import UniformTypeIdentifiers

// MARK: - Excel Export (CSV format)

/// Generates a CSV file of the 7-column evidence catalog.
/// Compatible with Excel, WPS, Numbers — uses UTF-8 BOM so Chinese headers render correctly.
///
/// CSV escaping/quoting is delegated to `TabularData` (`DataFrame.csvRepresentation`)
/// instead of hand-rolled string building. Each export is written as a sequence of
/// rectangular row blocks (case-info header, catalog, gap report) so the merged
/// report keeps its exact row layout; the UTF-8 BOM is prepended manually since
/// `CSVWritingOptions` has no BOM flag.
public enum ExcelExport {
    private static let logger = Logger(subsystem: "com.hardlaw.app", category: "ExcelExport")

    // MARK: - 目录导出

    /// Export the evidence catalog as a CSV file (案由/申请人/被申请人/日期 + 七列目录).
    public static func exportCatalog(_ caseFile: CaseFile) -> URL? {
        let fileName = "\(caseFile.caseName.isEmpty ? "证据目录" : caseFile.caseName)_证据目录.csv"
        return writeCSV([
            caseInfoRows(caseFile),
            blankSeparator,
            catalogRows(caseFile),
        ], fileName: fileName)
    }

    // MARK: - 缺口报告导出

    /// Export the gap report as CSV (案由/申请人/被申请人/日期 + 待核实清单).
    public static func exportGaps(_ caseFile: CaseFile) -> URL? {
        let fileName = "\(caseFile.caseName.isEmpty ? "待核实清单" : caseFile.caseName)_待核实清单.csv"
        return writeCSV([
            caseInfoRows(caseFile),
            blankSeparator,
            gapRows(caseFile),
        ], fileName: fileName)
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
        let fileName = "\(caseFile.caseName.isEmpty ? "证据目录" : caseFile.caseName)_证据目录与待核实清单.csv"
        return writeCSV([
            caseInfoRows(caseFile),
            blankSeparator,
            catalogRows(caseFile),
            blankSeparator,
            [["--- 待核实清单 ---"]],
            gapRows(caseFile),
        ], fileName: fileName)
    }

    // MARK: - 行构造（私有）

    /// 案件信息头：案由、申请人、被申请人、日期。
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
        ]
    }

    /// 空行分隔（单独成块，保证与手写 CSV 输出逐字节一致）。
    private static let blankSeparator: [[String]] = [[""]]

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

    /// Serialize each rectangular row block with TabularData (RFC 4180 escaping
    /// and quoting) and write the concatenated CSV to a temp file with a UTF-8
    /// BOM prefix so Excel/WPS recognize the encoding.
    private static func writeCSV(_ blocks: [[[String]]], fileName: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            var data = Data([0xEF, 0xBB, 0xBF]) // UTF-8 BOM for Excel/WPS Chinese-header recognition
            for rows in blocks {
                let columnCount = rows.map(\.count).max() ?? 0
                guard columnCount > 0 else { continue }
                let columns = (0..<columnCount).map { column -> AnyColumn in
                    Column<String>(
                        name: "c\(column)",
                        contents: rows.map { $0.indices.contains(column) ? $0[column] : "" }
                    ).eraseToAnyColumn()
                }
                let frame = DataFrame(columns: columns)
                data.append(try frame.csvRepresentation(options: CSVWritingOptions(includesHeader: false)))
            }
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            // 签名保持返回 URL?：失败时记录具体原因，由 UI 层根据 nil 展示用户可见反馈
            Self.logger.error("CSV 导出失败（\(fileName)）：\(error.localizedDescription, privacy: .public)")
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
}
