import HardlawKit

/// 劳动法法条库 — 替换内容审核 statutes
/// 每条 statute 对应一个可自动验证的法律要件
public enum LaborLawStatutes {

    // MARK: - 劳动关系确认

    /// 劳动关系成立 — 依据劳社部发〔2005〕12号第2条：合同/社保/工资支付/考勤/工作证任一即可
    public static let employmentRelationship = Statute(
        name: "劳动关系确认",
        description: "确认申请人与用人单位之间存在劳动关系",
        requiredEvidence: [
            EvidenceRequirement(evidence: "书面劳动合同", holder: .worker, onMissing: .block,
                alternatives: [
                    EvidenceRequirement("社会保险参保证明"),
                    EvidenceRequirement("工资银行流水"),
                    EvidenceRequirement("考勤记录"),
                    EvidenceRequirement("工作证/服务证"),
                ], minCount: 1),
        ],
        violations: [
            ViolationType(name: "未签书面合同", severity: .critical,
                description: "用人单位未与劳动者签订书面劳动合同，可能涉及双倍工资"),
            ViolationType(name: "劳动关系不明确", severity: .high,
                description: "无社保、无合同、无工资记录中的两项以上，劳动关系认定存疑")
        ],
        escalation: EscalationRule(maxViolations: 1, action: .block),
        defaultToReject: true, blocking: true
    )

    // MARK: - 工资标准与欠薪

    /// 拖欠工资 — 工资表由用人单位掌握（《劳动争议调解仲裁法》第6条、《工资支付暂行规定》第6条）
    public static let wageArrears = Statute(
        name: "拖欠工资",
        description: "确认用人单位未及时足额支付劳动报酬",
        requiredEvidence: [
            EvidenceRequirement(evidence: "工资银行流水", holder: .worker, onMissing: .block),
            EvidenceRequirement(evidence: "工资表", holder: .employer, onMissing: .flag,
                burdenBasis: "《劳动争议调解仲裁法》第6条、《工资支付暂行规定》第6条"),
        ],
        violations: [
            ViolationType(name: "欠薪事实不清", severity: .critical,
                description: "欠薪金额、期间缺乏独立证据证实"),
            ViolationType(name: "工资标准不一致", severity: .high,
                description: "劳动合同约定的工资与实际发放不一致"),
            ViolationType(name: "拖欠超过一个月", severity: .critical,
                description: "用人单位拖欠工资超过一个工资支付周期")
        ],
        escalation: EscalationRule(maxViolations: 1, action: .block),
        defaultToReject: true, blocking: true
    )

    /// 工资标准核实 — 非阻塞（差异说明即可）
    public static let salaryStandard = Statute(
        name: "工资标准核实",
        description: "确认劳动者月工资标准。注意：社保缴费基数通常为社平工资的60%-300%，不等于实际工资。",
        requiredEvidence: [
            EvidenceRequirement(evidence: "工资表", holder: .employer, onMissing: .flag,
                burdenBasis: "《工资支付暂行规定》第6条"),
            EvidenceRequirement(evidence: "银行工资流水", holder: .worker, onMissing: .flag),
        ],
        violations: [
            ViolationType(name: "工资标准差异说明", severity: .low,
                description: "社保缴费基数可能与实际工资存在差异（正常现象，非错误）")
        ],
        defaultToReject: false, blocking: false
    )

    // MARK: - 混同用工

    /// 关联企业混同用工
    public static let mixedEmployment = Statute(
        name: "关联企业混同用工",
        description: "依据《公司法》第23条第2款及混同用工事实，二被申请人承担连带责任",
        requiredEvidence: [
            EvidenceRequirement(evidence: "工商登记信息", holder: .worker, onMissing: .flag,
                alternatives: [EvidenceRequirement("国家企业信用信息公示系统打印件")], minCount: 1),
            EvidenceRequirement(evidence: "人事混同证据", holder: .employer, onMissing: .flag,
                burdenBasis: "《公司法》第23条第2款"),
            EvidenceRequirement(evidence: "财务混同证据", holder: .employer, onMissing: .flag),
        ],
        violations: [
            ViolationType(name: "关键人员身份未核实", severity: .high,
                description: "主张混同用工的关键管理人员身份仅有单方证据"),
            ViolationType(name: "财务混同证据不足", severity: .medium,
                description: "缺乏银行流水、发票、印章使用记录等证实财务混同"),
            ViolationType(name: "业务混同证据不足", severity: .medium,
                description: "缺乏项目管理、合同审批、汇报关系等证实业务混同"),
            ViolationType(name: "工资发放账户非用人单位账户", severity: .high,
                description: "个人账户发薪是认定混同/违法用工的强信号"),
            ViolationType(name: "财产混同程度可能不满足人格混同标准", severity: .medium,
                description: "仅人员/业务交叉不足以单独认定人格混同，需达到财产混同且无法区分")
        ],
        escalation: EscalationRule(maxViolations: 2, action: .flag),
        defaultToReject: true, blocking: true
    )

    // MARK: - 经济补偿金

    /// 经济补偿金计算（《劳动合同法》第47条）— 辅助计算，非阻塞
    public static let severanceCalculation = Statute(
        name: "经济补偿金计算",
        description: "依据《劳动合同法》第47条：每满一年一个月；六个月以上不满一年按一年；不满六个月半个月。月工资指解除前十二个月平均工资。高薪（超社平三倍）封顶十二年。",
        requiredEvidence: [
            EvidenceRequirement(evidence: "工资银行流水", holder: .worker, onMissing: .flag),
            EvidenceRequirement(evidence: "工资表", holder: .employer, onMissing: .flag),
        ],
        violations: [
            ViolationType(name: "平均工资计算错误", severity: .high,
                description: "基数应使用解除前十二个月平均工资，而非当月工资"),
            ViolationType(name: "工作年限争议", severity: .medium,
                description: "需确认起算日期和截止日期，含关联企业工龄合并（实施条例第10条）")
        ],
        defaultToReject: false, blocking: false
    )

    /// 加付赔偿金（《劳动合同法》第85条）— 责令决定需第三方（劳动行政部门）
    public static let additionalCompensation = Statute(
        name: "加付赔偿金",
        description: "依据《劳动合同法》第85条：用人单位逾期不支付劳动报酬的，责令按应付金额50%-100%加付赔偿金",
        requiredEvidence: [
            EvidenceRequirement(evidence: "劳动行政部门责令限期支付决定", holder: .thirdParty, onMissing: .prompt,
                burdenBasis: "《劳动合同法》第85条"),
            EvidenceRequirement(evidence: "工资银行流水", holder: .worker, onMissing: .flag),
        ],
        violations: [
            ViolationType(name: "行政责令已下达", severity: .critical,
                description: "劳动行政部门已下达责令限期支付决定，用人单位逾期未履行")
        ],
        defaultToReject: false, blocking: false
    )

    /// 被迫解除劳动合同（《劳动合同法》第38条）
    public static let forcedTermination = Statute(
        name: "被迫解除劳动合同",
        description: "依据《劳动合同法》第38条：用人单位未及时足额支付劳动报酬的，劳动者可以解除劳动合同",
        requiredEvidence: [
            EvidenceRequirement(evidence: "被迫解除通知书", holder: .worker, onMissing: .block),
            EvidenceRequirement(evidence: "EMS邮寄凭证", holder: .worker, onMissing: .block),
        ],
        violations: [
            ViolationType(name: "解除程序瑕疵", severity: .high,
                description: "被迫解除通知书未送达或送达方式不符合法定要求"),
            ViolationType(name: "解除理由不成立", severity: .critical,
                description: "解除理由不满足《劳动合同法》第38条的条件")
        ],
        defaultToReject: true, blocking: true
    )

        /// 仲裁时效（《劳动争议调解仲裁法》第27条）
    public static let arbitrationLimitation = Statute(
        name: "仲裁时效",
        description: "依据《劳动争议调解仲裁法》第27条：劳动争议申请仲裁的时效期间为一年。劳动关系存续期间因拖欠劳动报酬发生争议的，不受一年限制；劳动关系终止的，应在终止之日起一年内提出。",
        requiredEvidence: [
            EvidenceRequirement(evidence: "劳动关系终止日期", holder: .worker, onMissing: .flag),
        ],
        violations: [
            ViolationType(name: "时效即将届满", severity: .critical,
                description: "距仲裁时效届满不足30日，应立即申请仲裁或取得时效中断证据"),
            ViolationType(name: "时效可能已过", severity: .critical,
                description: "劳动关系终止后超过一年，全部请求可能面临时效抗辩"),
            ViolationType(name: "时效中断证据缺失", severity: .high,
                description: "主张时效中断但缺乏相应证据")
        ],
        escalation: EscalationRule(maxViolations: 1, action: .block),
        defaultToReject: true, blocking: true
    )

    /// Convenience: statutes for gap detection.
    /// burdenOfProof retired — employer evidence burden is now native to `.employer` holder.
    public static let gapDetectionBook = StatuteBook(statutes: [arbitrationLimitation, employmentRelationship, wageArrears, mixedEmployment, salaryStandard])
}
