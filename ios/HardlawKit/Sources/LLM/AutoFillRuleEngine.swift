import Foundation

// MARK: - AutoFillRuleEngine

/// Deterministic auto-fill engine implementing `LLMBackend`.
/// Routes between document-level and metadata extraction based on prompt markers.
/// All output is source-grounded — numbers come verbatim from the OCR text.
///
/// This is the fallback when MLX is unavailable; `FailSafeLLM` already composes
/// `MLXLLM → AutoFillRuleEngine` automatically.
public actor AutoFillRuleEngine: LLMBackend {

    public init() {}

    // MARK: - LLMBackend

    public func judge(_ prompt: String) async throws -> String {
        if prompt.contains("## 原始证据文字") {
            return handleDocumentPrompt(prompt)
        } else if prompt.contains("## 案件文档") {
            return handleMetadataPrompt(prompt)
        }
        // Default: return empty JSON (safe no-op)
        return #"{"classification":"","proof_content":"","proof_purpose":"","numbers_cited":[]}"#
    }

    // MARK: - Document-level extraction

    private func handleDocumentPrompt(_ prompt: String) -> String {
        // Extract the document name
        let name = extractContentField("## 文档名称", from: prompt) ?? ""

        // Extract the OCR text
        guard let ocrText = extractContentField("## 原始证据文字", from: prompt) else {
            return #"{"classification":"","proof_content":"","proof_purpose":"","numbers_cited":[]}"#
        }

        // Classify the document
        let category = DocumentClassifier.classify(fileName: name, ocrText: ocrText)

        // Extract proof content: verbatim lines containing numbers or key entities
        let proofContent = extractProofContent(from: ocrText)

        // Template-based proof purpose
        let proofPurpose = category.map { purposeTemplate(for: $0) } ?? ""

        // Extract numbers verbatim from source
        let numbersCited = extractNumbers(from: ocrText)

        // Build JSON response
        let classification = category?.rawValue ?? ""
        let escapedContent = escapeJSON(proofContent)
        let escapedPurpose = escapeJSON(proofPurpose)
        let numbersJSON = numbersCited.map { "\"\(escapeJSON($0))\"" }.joined(separator: ",")

        return """
        {"classification":"\(escapeJSON(classification))","proof_content":"\(escapedContent)","proof_purpose":"\(escapedPurpose)","numbers_cited":[\(numbersJSON)]}
        """
    }

    // MARK: - Metadata extraction

    private func handleMetadataPrompt(_ prompt: String) -> String {
        // Parse all document sections
        let docs = extractAllContentFields("## 案件文档", from: prompt)
        let allText = docs.joined(separator: "\n\n")

        // Applicant: look for 申请人/申诉人 pattern
        let applicant = extractField(pattern: #"(?:申请人|申诉人)[：:]\s*(.+?)(?:\n|$)"#, from: allText) ?? ""

        // Respondent: look for 被申请人/被诉人 pattern
        let respondent = extractField(pattern: #"(?:被申请人|被诉人)[：:]\s*(.+?)(?:\n|$)"#, from: allText) ?? ""

        // Case name: look for 案由 or the first title line with 劳动/争议/工资/解除
        let caseName = extractCaseName(from: allText)

        // Claims: look for 请求事项 / 仲裁请求 sections
        let claims = extractClaims(from: allText)

        // Build JSON
        let claimsJSON = claims.map { "\"\(escapeJSON($0))\"" }.joined(separator: ",")

        return """
        {"case_name":"\(escapeJSON(caseName))","applicant":"\(escapeJSON(applicant))","respondent":"\(escapeJSON(respondent))","claims":[\(claimsJSON)]}
        """
    }

    // MARK: - Extraction helpers

    /// Extract a named section from the prompt (e.g. `## 原始证据文字`).
    private func extractContentField(_ header: String, from text: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: header))\\s*\\n([\\s\\S]*?)(?=\\n##|\\Z)"
        return extractField(pattern: pattern, from: text)
    }

    /// Extract all text between a header and the next header or end.
    private func extractAllContentFields(_ header: String, from text: String) -> [String] {
        // Find the header and collect all document sections
        var docs: [String] = []
        let pattern = "### 文档\\d+：[^\\n]+\\n([\\s\\S]*?)(?=\\n### 文档|\\n## 输出|\\Z)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        for match in matches {
            if let range = Range(match.range(at: 1), in: text) {
                docs.append(String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return docs
    }

    /// Generic regex field extractor — first capture group.
    private func extractField(pattern: String, from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract case name from document text.
    private func extractCaseName(from text: String) -> String {
        // Try explicit 案由 first
        if let found = extractField(pattern: #"\b案由[：:]\s*(.+?)(?:\n|$)"#, from: text) {
            return found
        }
        // Try first line with common dispute keywords
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            if s.contains("劳动") && (s.contains("争议") || s.contains("工资") || s.contains("解除") || s.contains("赔偿")) {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    /// Extract claims from document text.
    private func extractClaims(from text: String) -> [String] {
        // Find 仲裁请求 / 请求事项 section
        var claimsSection: String?
        if let section = extractField(pattern: #"(?:仲裁请求|请求事项|申诉请求|请求)[：:]\s*([\s\S]*?)(?=\n(?:事实|理由|申请|证据)|\z)"#, from: text) {
            claimsSection = section
        }

        guard let section = claimsSection else { return [] }

        // Split by numbered items: 1. / 1、/ （1）/ 一、
        let lines = section.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.isEmpty { return [] }

        // If multiple lines, each is a claim; if single line, try to split by semicolons
        if lines.count > 1 {
            return lines.map { cleanClaimLine(String($0)) }.filter { !$0.isEmpty }
        } else {
            let parts = section.components(separatedBy: CharacterSet(charactersIn: "；;"))
            return parts.map { cleanClaimLine($0) }.filter { !$0.isEmpty }
        }
    }

    /// Clean a claim line: strip numbering prefixes like "1、" or "1.".
    private func cleanClaimLine(_ line: String) -> String {
        let cleaned = line.replacingOccurrences(
            of: #"^[\s]*(?:\d+[\.、．)]|[（(]\d+[）)])[\s]*"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    /// Extract proof content: verbatim lines containing numbers or key entity keywords.
    private func extractProofContent(from ocrText: String) -> String {
        let lines = ocrText.split(separator: "\n", omittingEmptySubsequences: true)
        let numberPattern = try! NSRegularExpression(pattern: #"\d+"#, options: [])
        let keywordSet: Set<String> = [
            "元", "月", "日", "号", "合同", "公司", "有限", "工资",
            "姓名", "身份证", "参保", "解除", "通知", "EMS", "社保",
            "公积金", "处罚", "拖欠", "欠薪",
        ]

        var relevant: [String] = []
        for line in lines {
            let s = String(line)
            let hasNumber = numberPattern.firstMatch(in: s, options: [], range: NSRange(s.startIndex..<s.endIndex, in: s)) != nil
            let hasKeyword = keywordSet.contains { s.localizedCaseInsensitiveContains($0) }
            if hasNumber || hasKeyword {
                relevant.append(s.trimmingCharacters(in: .whitespaces))
                if relevant.count >= 6 { break } // Max 6 lines
            }
        }
        return relevant.joined(separator: "；")
    }

    /// Extract all numbers from OCR text (for numbers_cited).
    private func extractNumbers(from text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"[\d,，]+\.?\d*\s*(?:元|万|人|天|年|月|日|号)"#, options: [])
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = pattern.matches(in: text, options: [], range: nsRange)
        var seen = Set<String>()
        var numbers: [String] = []
        for match in matches {
            if let range = Range(match.range, in: text) {
                let num = String(text[range]).trimmingCharacters(in: .whitespaces)
                if seen.insert(num).inserted {
                    numbers.append(num)
                }
            }
        }
        return Array(numbers.prefix(20)) // Max 20 numbers
    }

    /// Template proof purpose per evidence category.
    private func purposeTemplate(for category: EvidenceCategory) -> String {
        switch category {
        case .laborContract:
            return "证明双方存在劳动关系及劳动合同约定的岗位、期限和工资标准"
        case .bankStatement:
            return "证明用人单位按月支付工资的金额、发放主体及发放方式"
        case .salaryTable:
            return "证明申请人的工资结构（基本工资、津贴、补贴）及实际发放金额"
        case .socialInsurance:
            return "证明申请人与被申请人存在社会保险参保关系及参保期间"
        case .businessRegistration:
            return "证明被申请人的工商登记主体资格及股东信息"
        case .personnelOverlap:
            return "证明关联企业之间存在人事混同，构成混同用工"
        case .financialOverlap:
            return "证明关联企业之间存在财务混同，构成混同用工"
        case .terminationNotice:
            return "证明申请人依据《劳动合同法》第38条被迫解除劳动关系的事实"
        case .emsReceipt:
            return "证明被迫解除劳动关系通知书已通过EMS邮寄送达被申请人"
        case .dismissalNotice:
            return "证明被申请人单方解除或终止劳动关系的事实"
        case .attendanceRecord:
            return "证明申请人的出勤情况和加班事实"
        case .workHistory:
            return "证明申请人在被申请人处的工龄和累计工作年限"
        case .annualLeave:
            return "证明申请人应享受的年休假天数及实际休假情况"
        case .wageStandard:
            return "证明申请人的月工资标准，用于计算各项赔偿基数"
        case .entryDate:
            return "证明申请人的入职时间，用于计算工龄和赔偿年限"
        case .terminationDate:
            return "证明劳动关系终止的具体日期，用于确定仲裁时效"
        case .administrativeDecision:
            return "证明劳动行政部门已对被申请人拖欠工资的行为作出处理决定"
        case .housingFund:
            return "证明申请人的住房公积金缴存情况和缴存基数"
        case .penaltyNotice:
            return "证明被申请人因拖欠工资受到行政处罚的事实"
        case .arrearsStatement:
            return "证明被申请人拖欠申请人工资的具体金额"
        case .chatRecord:
            return "证明双方就劳动关系事项的沟通内容和事实"
        case .other:
            return "作为劳动争议案件的辅助证据材料"
        }
    }

    /// JSON string escaping.
    private func escapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
