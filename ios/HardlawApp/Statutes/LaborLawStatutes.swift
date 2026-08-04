import HardlawKit

/// 劳动法法条库 — 替换内容审核 statutes
/// 每条 statute 对应一个可自动验证的法律要件
public enum LaborLawStatutes {

    // MARK: - 劳动关系确认

    /// 劳动关系成立
    public static let employmentRelationship = Statute(
        name: "劳动关系确认",
        description: "确认申请人与用人单位之间存在劳动关系",
        requiredEvidence: ["社会保险参保证明", "书面劳动合同"],
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

    /// 拖欠工资
    public static let wageArrears = Statute(
        name: "拖欠工资",
        description: "确认用人单位未及时足额支付劳动报酬",
        requiredEvidence: ["工资银行流水", "工资表"],
        violations: [
            ViolationType(name: "欠薪事实不清", severity: .critical,
                description: "欠薪金额、期间缺乏独立证据证实"),
            ViolationType(name: "工资标准不一致", severity: .high,
                description: "劳动合同约定的工资与实际发放不一致，或社保基数、公积金基数、工资表数额不一致"),
            ViolationType(name: "拖欠超过一个月", severity: .critical,
                description: "用人单位拖欠工资超过一个工资支付周期")
        ],
        escalation: EscalationRule(maxViolations: 1, action: .block),
        defaultToReject: true, blocking: true
    )

    /// 工资标准核实（社保基数≠工资标准是常见认知误区，需标注而非报错）
    public static let salaryStandard = Statute(
        name: "工资标准核实",
        description: "确认劳动者月工资标准。注意：社保缴费基数通常为社平工资的60%-300%，不等于实际工资。",
        requiredEvidence: ["工资表", "银行工资流水"],
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
        description: "确认二被申请人存在工商关联、人事混同、财务混同、业务混同，应承担连带责任",
        requiredEvidence: ["工商登记信息", "人事混同证据", "财务混同证据"],
        violations: [
            ViolationType(name: "关键人员身份未核实", severity: .high,
                description: "主张混同用工的关键管理人员身份仅有单方证据，缺乏社保记录或工商登记等独立证据佐证"),
            ViolationType(name: "财务混同证据不足", severity: .medium,
                description: "缺乏银行流水、发票、印章使用记录等证实财务混同"),
            ViolationType(name: "业务混同证据不足", severity: .medium,
                description: "缺乏项目管理、合同审批、汇报关系等证实业务混同")
        ],
        escalation: EscalationRule(maxViolations: 2, action: .flag),
        defaultToReject: true, blocking: true
    )

    // MARK: - 经济补偿金

    /// 经济补偿金计算（《劳动合同法》第47条）
    public static let severanceCalculation = Statute(
        name: "经济补偿金计算",
        description: "依据《劳动合同法》第47条：经济补偿按劳动者在本单位工作的年限，每满一年支付一个月工资的标准向劳动者支付。月工资指劳动合同解除前十二个月的平均工资。",
        requiredEvidence: ["工资银行流水", "工资表"],
        violations: [
            ViolationType(name: "平均工资计算错误", severity: .high,
                description: "经济补偿金基数应使用解除前十二个月平均工资，而非当月工资"),
            ViolationType(name: "工作年限争议", severity: .medium,
                description: "工作年限计算存在争议，需确认起算日期和截止日期")
        ],
        defaultToReject: false, blocking: false
    )

    /// 加付赔偿金（《劳动合同法》第85条）
    public static let additionalCompensation = Statute(
        name: "加付赔偿金",
        description: "依据《劳动合同法》第85条：用人单位逾期不支付劳动报酬的，责令其按应付金额50%-100%加付赔偿金",
        requiredEvidence: ["行政处罚告知书", "工资银行流水"],
        violations: [
            ViolationType(name: "行政责令已下达", severity: .critical,
                description: "劳动行政部门已下达限期改正指令，用人单位逾期未履行")
        ],
        defaultToReject: false, blocking: false
    )

    /// 被迫解除劳动合同（《劳动合同法》第38条）
    public static let forcedTermination = Statute(
        name: "被迫解除劳动合同",
        description: "依据《劳动合同法》第38条：用人单位未及时足额支付劳动报酬的，劳动者可以解除劳动合同",
        requiredEvidence: ["被迫解除通知书", "EMS邮寄凭证"],
        violations: [
            ViolationType(name: "解除程序瑕疵", severity: .high,
                description: "被迫解除通知书未送达或送达方式不符合法定要求"),
            ViolationType(name: "解除理由不成立", severity: .critical,
                description: "解除理由不满足《劳动合同法》第38条的条件")
        ],
        defaultToReject: true, blocking: true
    )

    /// 举证责任提示（程序性规则，非实质性 statute）
    public static let burdenOfProof = Statute(
        name: "举证责任提示",
        description: "依据《劳动争议调解仲裁法》第6条：与争议事项有关的证据属于用人单位掌握管理的，用人单位应当提供",
        requiredEvidence: [],
        violations: [
            ViolationType(name: "用人单位举证缺失", severity: .low,
                description: "该证据依法应由用人单位提供，不作为申请人证据缺口")
        ],
        defaultToReject: false, blocking: false
    )
}
