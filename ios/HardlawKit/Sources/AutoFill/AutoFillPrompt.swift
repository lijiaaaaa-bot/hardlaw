import Foundation

/// Prompt builders for AI auto-fill — mirrors the Court's `_buildJudgmentPrompt` pattern.
/// All prompts include an explicit OUTPUT CONTRACT (JSON schema) so the LLM knows
/// exactly what to return, and the parser knows exactly what to expect.
public enum AutoFillPrompt {

    // MARK: - Per-document prompt

    /// Build a prompt for classifying a document and extracting proof content/purpose.
    ///
    /// - Parameters:
    ///   - name: The file name of the evidence document.
    ///   - candidates: Top-N classification candidates from `DocumentClassifier.classifyTopN`.
    ///   - ocrText: OCR-extracted text (will be truncated to 2000 chars).
    ///   - claims: The case's arbitration claims. When provided, `proof_purpose`
    ///     must tie this evidence to a specific claim (by number or verbatim text).
    /// - Returns: A prompt string suitable for `LLMBackend.judge(_:)`.
    public static func documentPrompt(
        name: String,
        candidates: [String],
        ocrText: String,
        claims: [String] = []
    ) -> String {
        let truncated = String(ocrText.prefix(2000))
        let candidateList = candidates.isEmpty
            ? "根据文本内容自行判断"
            : candidates.joined(separator: "、")
        let claimsList = claims.isEmpty
            ? "（未提供）"
            : claims.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")

        return """
        你是劳动争议案件的证据分析助手。请审阅以下证据文档，输出结构化分析。

        ## 文档名称
        \(name)

        ## 候选证据类型
        \(candidateList)

        ## 本案仲裁请求
        \(claimsList)

        ## 原始证据文字
        \(truncated)

        ## 输出要求
        你必须输出一个 JSON 对象，包含以下字段：
        {
          "classification": "证据类型（从候选列表中选最匹配的，或自行判断）",
          "proof_content": "证明内容——用1-2句中文概括这份证据能证明什么事实。所有数字、金额、日期、人名必须与原文逐字一致，不得编造。",
          "proof_purpose": "证明目的——这份证据用于支持上面哪项仲裁请求（引用请求编号或原文，如：支持请求1追索拖欠工资）。若与请求无直接关联，说明其辅助证明作用。",
          "numbers_cited": ["文中出现的所有金额和关键数字（原文照抄）"]
        }

        重要规则：
        - 所有金额和数字必须从原文逐字照抄，不得推算或编造。
        - proof_content 必须基于原文事实，不得臆断。
        - proof_purpose 必须指向具体的仲裁请求，不要泛泛而谈。
        - 如果原文信息不足，宁可返回空字符串也不要编造。
        - 只输出 JSON，不要输出其他解释文字。

        {
          "classification":
        """
    }

    // MARK: - Metadata extraction prompt

    /// Build a prompt for extracting case metadata from key documents.
    ///
    /// - Parameter documents: (name, OCR text) pairs for key documents —
    ///   typically 仲裁申请书, 劳动合同, 解除通知书.
    /// - Returns: A prompt string suitable for `LLMBackend.judge(_:)`.
    public static func metadataPrompt(
        documents: [(name: String, text: String)]
    ) -> String {
        var docsSection = ""
        for (i, doc) in documents.enumerated() {
            let truncated = String(doc.text.prefix(1200))
            docsSection += """
            ### 文档\(i + 1)：\(doc.name)
            \(truncated)

            """
        }

        return """
        你是劳动争议案件的分析助手。请从以下法律文书中提取案件核心信息。

        ## 案件文档
        \(docsSection)
        ## 输出要求
        你必须输出一个 JSON 对象，包含以下字段：
        {
          "case_name": "案由——劳动争议的具体类型（如：拖欠工资、被迫解除劳动合同、违法解除劳动合同赔偿金等）",
          "applicant": "申请人姓名（劳动者）",
          "respondent": "被申请人名称（用人单位全称）",
          "claims": ["仲裁请求1", "仲裁请求2", "..."]
        }

        重要规则：
        - 所有姓名和公司名称必须从原文逐字照抄。
        - claims 是仲裁请求的列表，每项一个字符串。
        - 如果某字段无法从文档中确定，返回空字符串 ""。
        - 只输出 JSON，不要输出其他解释文字。

        {
          "case_name":
        """
    }

    // MARK: - Gap detection prompt (batch-mode)

    /// Build a prompt for detecting evidence gaps across all documents.
    public static func gapDetectionPrompt(
        claims: [String],
        evidenceSummary: [(name: String, category: String, ocrPreview: String)]
    ) -> String {
        var summarySection = ""
        for (i, item) in evidenceSummary.enumerated() {
            let preview = String(item.ocrPreview.prefix(200))
            summarySection += "\(i + 1). \(item.name) [\(item.category)]: \(preview)\n"
        }

        let claimsList = claims.isEmpty ? "（无明确请求）" : claims.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")

        return """
        你是劳动争议案件的证据审查专家。请审查已有证据，找出证明链中的缺口。

        ## 仲裁请求
        \(claimsList)

        ## 已有证据清单
        \(summarySection)

        ## 输出要求
        你必须输出一个 JSON 数组，列出缺失的关键证据：
        [
          {
            "gap": "缺失的证据类型（如：书面劳动合同、工资银行流水、EMS邮寄凭证等）",
            "severity": "high/medium/low",
            "claim": "关联的仲裁请求",
            "reason": "为什么需要这份证据（引用法律规定或举证责任规则）"
          }
        ]

        重要规则：
        - 只列出确实缺失且对案件关键的证据。
        - 劳动者持有的证据缺失标注为 high，用人单位持有的缺失标注为 medium。
        - 如果证据已足够，返回空数组 []。
        - 只输出 JSON，不要输出其他解释文字。

        [
        """
    }
}
