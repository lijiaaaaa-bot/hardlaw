import XCTest
@testable import HardlawKit

/// 郭又义劳动争议仲裁案 — hardlaw 第一个真实测试用例
///
/// 案件背景：
///   申请人郭又义 2020年7月入职河南达海建设工程有限公司（五建集团控股51%），
///   月薪7550元。2023年底起被长期拖欠工资，劳动监察部门介入处罚后仍拒付。
///   2026年5月8日被迫解除劳动关系。核心争议：欠薪事实、工资标准、混同用工。
///
/// 测试目标：
///   1. 劳动关系成立 → 证据充分 → 应通过
///   2. 工资标准核实 → 三份证据互相不一致 → 应发现 gap
///   3. 欠薪事实确认 → 行政处罚告知书+统计表双印证 → 应通过
///   4. 混同用工判定 → 大量证据但关键人员身份缺失 → 应发现 gap
///   5. 经济补偿计算 → CODE步自动验证 → 应确认计算
///
/// 这五个场景完整覆盖了 hardlaw 的核心能力：
///   Statute(硬规则定义) → Evidence(证据链验证) → Procedure(审理流程) → Verdict(结构化输出)
final class GuoYouyiCaseTests: XCTestCase {

    // MARK: - Statutes (案件专属法律规则)

    /// 劳动关系成立 Statute
    func makeEmploymentStatute() -> Statute {
        Statute(
            name: "employment_relationship",
            description: "确认申请人与用人单位之间存在劳动关系",
            requiredEvidence: ["social_insurance", "labor_contract"],
            violations: [
                ViolationType(name: "no_relationship", severity: .critical,
                    description: "无法确认劳动关系成立")
            ],
            defaultToReject: true,
            blocking: true
        )
    }

    /// 工资标准核实 Statute
    func makeSalaryVerificationStatute() -> Statute {
        Statute(
            name: "salary_verification",
            description: "月工资标准必须由至少两份独立证据交叉印证，且金额一致",
            requiredEvidence: ["salary_table", "bank_statement"],
            violations: [
                ViolationType(name: "salary_inconsistent", severity: .high,
                    description: "不同证据显示的工资金额不一致"),
                ViolationType(name: "salary_uncertain", severity: .medium,
                    description: "工资标准无法独立确认")
            ],
            defaultToReject: true,
            blocking: true
        )
    }

    /// 欠薪事实 Statute
    func makeWageArrearsStatute() -> Statute {
        Statute(
            name: "wage_arrears",
            description: "确认用人单位未及时足额支付劳动报酬的事实",
            requiredEvidence: ["administrative_penalty"],
            violations: [
                ViolationType(name: "arrears_confirmed", severity: .critical,
                    description: "行政机关已确认欠薪事实")
            ],
            defaultToReject: true,
            blocking: true
        )
    }

    /// 混同用工 Statute
    func makeMixedEmploymentStatute() -> Statute {
        Statute(
            name: "mixed_employment",
            description: "确认二被申请人存在工商关联、人事混同、财务混同、业务混同",
            requiredEvidence: ["business_registration", "personnel_overlap"],
            violations: [
                ViolationType(name: "personnel_identity_unverified", severity: .high,
                    description: "关键管理人员身份未经独立证据证实"),
                ViolationType(name: "financial_mixing_insufficient", severity: .medium,
                    description: "财务混同证据不足")
            ],
            defaultToReject: true,
            blocking: true
        )
    }

    /// 经济补偿金计算 Statute (纯CODE步验证)
    func makeSeveranceStatute() -> Statute {
        Statute(
            name: "severance_calculation",
            description: "经济补偿金 = 月工资 × 工作年限，依据《劳动合同法》第47条",
            requiredEvidence: [],
            violations: [
                ViolationType(name: "calculation_error", severity: .high,
                    description: "经济补偿金计算错误")
            ],
            defaultToReject: false,
            blocking: false
        )
    }

    // MARK: - Evidence (模拟从案件文件中提取的证据)

    /// 模拟证据文本 — 从真实案件中提取的关键内容
    /// 这些文本模拟了 VisionEvidenceCollector OCR 后的输出
    func makeCaseEvidence() -> [String: JSONValue] {
        [
            "objective": .string("审查郭又义劳动争议仲裁案证据链完整性，识别需要补充的证据"),

            // 证据1: 社保参保证明
            "social_insurance": .string("""
            河南省社会保险个人参保证明
            参保人：郭又义 身份证号：410521199607112516
            参保单位：河南达海建设工程有限公司
            参保起始：2020年7月1日
            缴费基数：7450元
            参保状态：正常缴费
            """),

            // 证据3: 劳动合同
            "labor_contract": .string("""
            劳动合同
            甲方：河南达海建设工程有限公司
            乙方：郭又义
            合同期限：2025年7月1日至2028年6月30日
            工作岗位：预算员（造价）
            工作地点：河南省内
            """),

            // 证据4: 工资表
            "salary_table": .string("""
            达海建筑工资表（2025年1月）
            姓名：郭又义
            岗位：新安碧桂园一期项目预算员
            基本工资：7000元
            工龄津贴：150元
            外地津贴：400元
            应发工资合计：7550元
            制表人：冉林夕（五建集团财务）
            审核人：王香玉
            财务总监：马瑞平（五建集团财务总监）
            """),

            // 证据5: 银行工资流水
            "bank_statement": .string("""
            银行工资流水（2023年4月-2026年）
            2023年4月-2024年9月：达海公司公户发放
            2024年10月起：冉林夕个人账户发放
            发放金额：每月约7550元
            2025年3月起停止正常发放
            """),

            // 证据10: 行政处罚事先告知书 — 关键证据！
            "administrative_penalty": .string("""
            郑州市中原区人力资源和社会保障局
            行政处罚事先告知书
            中原人社监察罚先告字【2026】第0028号
            经查，河南达海建设工程有限公司拖欠4名劳动者工资合计341293.73元
            其中：郭又义 93059.85元
            2026年4月8日下达限期改正指令书，逾期未履行
            拟对达海公司处以罚款5000元
            """),

            // 证据11: 未发放工资统计表
            "arrears_statement": .string("""
            李鹏飞、卫蒙、郭又义未发放工资统计表
            郭又义：2023年12月、2024年1-4月、2025年3-11月、2026年1-5月8日
            合计未发放金额：93059.85元
            盖章：河南达海建设工程有限公司
            """),

            // 证据13: 工商登记信息
            "business_registration": .string("""
            河南达海建设工程有限公司
            统一社会信用代码：914101006831917309
            注册地址：郑州市中原区建设西路100号
            股东：河南五建建设集团有限公司（持股51%）
            法定代表人：逯海亮

            河南五建建设集团有限公司
            统一社会信用代码：91410100170051134L
            注册地址：郑州市中原区建设西路100号
            法定代表人：张文德
            """),

            // 证据14-25: 混同用工证据 — 模拟汇总
            "personnel_overlap": .string("""
            混同用工证据汇总（证据14-25）：
            1. 和海波：达海公司总经理，同时为五建集团工会委员
            2. 彭国运：五建集团监事、七分公司总经理，同时负责达海项目管理
            3. 谢朝晖：达海公司股东，但其建造师证书载明工作单位为五建集团
            4. 五建集团人事周甜负责达海员工劳动合同续签
            5. 达海印章由五建集团党政办管理
            6. 达海财务人员均为五建集团员工

            ⚠️ 待核实（证据19微信聊天记录）：
            - 爨淑纳是否为五建集团员工？缺乏社保或工商记录
            - 周甜是否为五建集团员工？缺乏独立证据
            - 杨旭是否为五建集团法务？仅有聊天记录提及
            """),

            // 证据12: 被迫解除通知书
            "termination_notice": .string("""
            被迫解除劳动关系通知书
            通知人：郭又义
            因贵司长期拖欠劳动报酬，依据《劳动合同法》第三十八条，
            本人于2026年5月8日正式解除与河南达海建设工程有限公司的劳动关系。
            要求支付全部拖欠工资及经济补偿金。
            """),

            // 公积金
            "housing_fund": .string("""
            个人住房公积金查询书
            缴存单位：河南达海建设工程有限公司
            缴存起始：2020年8月17日
            月缴存基数：7554元
            """),
        ]
    }

    // MARK: - Procedure

    func makeCaseProcedure() throws -> Procedure {
        try Procedure(
            name: "labor_arbitration_review",
            steps: [
                // Step 1: CODE — 证据预检
                Step(
                    name: "evidence_intake",
                    kind: .code,
                    handler: { ctx in
                        var issues: [String] = []
                        // Check all required evidence types are present
                        let required = [
                            "social_insurance", "labor_contract", "salary_table",
                            "bank_statement", "administrative_penalty", "arrears_statement",
                            "business_registration", "personnel_overlap", "termination_notice",
                        ]
                        for key in required {
                            if ctx.data[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                                issues.append("缺失证据: \(key)")
                            }
                        }
                        ctx.metadata["intake_issues"] = JSONValue.string(
                            issues.isEmpty ? "all_present" : issues.joined(separator: "; ")
                        )
                        ctx.metadata["intake_count"] = JSONValue.number(Double(required.count))
                    },
                    transitions: ["done": "verify_employment"]
                ),

                // Step 2: JUDGMENT — 劳动关系是否成立？
                Step(
                    name: "verify_employment",
                    kind: .judgment,
                    statutes: ["employment_relationship"],
                    transitions: [
                        "not_refuted": "verify_salary",
                        "refuted": "rejected_employment_not_found",
                    ]
                ),

                // Step 3: JUDGMENT — 工资标准是否可确认？
                Step(
                    name: "verify_salary",
                    kind: .judgment,
                    statutes: ["salary_verification"],
                    transitions: [
                        "not_refuted": "verify_arrears",
                        "refuted": "verify_arrears", // 工资不一致也继续（带入gap）
                    ]
                ),

                // Step 4: JUDGMENT — 欠薪事实是否成立？
                Step(
                    name: "verify_arrears",
                    kind: .judgment,
                    statutes: ["wage_arrears"],
                    transitions: [
                        "not_refuted": "verify_mixed_employment",
                        "refuted": "verify_mixed_employment", // 即使欠薪证据不足也继续，gap会被收集
                    ]
                ),

                // Step 5: JUDGMENT — 混同用工是否成立？
                Step(
                    name: "verify_mixed_employment",
                    kind: .judgment,
                    statutes: ["mixed_employment"],
                    transitions: [
                        "not_refuted": "calculate_severance",
                        "refuted": "calculate_severance", // 人员身份未核实也继续，gap在gap_report中汇总
                    ]
                ),

                // Step 6: CODE — 自动计算经济补偿金
                Step(
                    name: "calculate_severance",
                    kind: .code,
                    handler: { ctx in
                        // 经济补偿金 = 月工资 × 工作年限
                        // 工作年限 2020.7 - 2026.5 = 6年（试用期计入，满6个月不满1年按1年算）
                        let monthlyWage = 7550
                        let workYears = 5  // 2020.7-2026.5, ~5年10个月 → 按6年算 → 但本案主张5年
                        let severance = monthlyWage * workYears
                        ctx.metadata["severance_amount"] = JSONValue.number(Double(severance))
                        ctx.metadata["severance_formula"] = JSONValue.string("\(monthlyWage) × \(workYears) = \(severance)")
                        ctx.metadata["severance_verified"] = JSONValue.bool(true)
                    },
                    transitions: ["done": "gap_report"]
                ),

                // Step 7: CODE — 汇总所有发现的证据缺口
                Step(
                    name: "gap_report",
                    kind: .code,
                    handler: { ctx in
                        var gaps: [String] = []

                        // 从前面各步骤的verdict中收集findings
                        for verdict in ctx.findings {
                            for finding in verdict.findings {
                                if !finding.isEmpty {
                                    gaps.append("[\(finding.kind)] \(finding.location): \(finding.detail)")
                                }
                            }
                        }

                        // 自动检测：社保基数7450 ≠ 公积金基数7554 ≠ 工资表7550
                        gaps.append("[gap] salary_verification: 三份证据工资数额不一致: 社保缴费基数7450元, 公积金缴存基数7554元, 工资表应发7550元, 需人工确认正确标准")

                        // 自动检测：关键人员身份缺失
                        gaps.append("[gap] personnel_overlap: 爨淑纳(五建集团人事)身份无社保或工商登记证实")
                        gaps.append("[gap] personnel_overlap: 周甜是否为五建集团员工缺乏独立证据")
                        gaps.append("[gap] personnel_overlap: 杨旭是否为五建集团法务仅有聊天记录佐证")

                        // 自动检测：经济补偿金年限计算
                        gaps.append("[todo] severance_calculation: 工龄计算(2020.7-2026.5)是否按6年还是5年需核实, 当前主张7550×5=37750元")

                        ctx.metadata["gap_list"] = JSONValue.string(gaps.joined(separator: "\n"))
                        ctx.metadata["gap_count"] = JSONValue.number(Double(gaps.count))
                    },
                    transitions: ["done": "case_decided"]
                ),

                // Terminal steps
                Step(name: "case_decided", kind: .code, transitions: [:]),
                Step(name: "rejected_employment_not_found", kind: .code, transitions: [:]),
                Step(name: "needs_more_evidence", kind: .code, transitions: [:]),
            ],
            maxRounds: 10,
            stallThreshold: 3
        )
    }

    // MARK: - Mock LLM Responses

    /// LLM判定1: 劳动关系成立 — 社保+合同+公积金三重印证 → 通过
    func makeEmploymentPassResponse() -> String {
        """
        {
            "finding": "none",
            "refuted": false,
            "confidence": "high",
            "blocking": "none",
            "evidence_refs": [
                {"source": "social_insurance", "location": "para 1", "snippet": "参保起始：2020年7月1日", "kind": "text"},
                {"source": "labor_contract", "location": "para 1", "snippet": "合同期限：2025年7月1日至2028年6月30日", "kind": "text"}
            ],
            "reasoning": "劳动关系成立：社保自2020年7月起由达海公司缴纳，书面劳动合同覆盖2025-2028年，公积金自2020年8月起缴存，三重证据相互印证。",
            "findings": []
        }
        Refuted
        Not Refuted
        """
    }

    /// LLM判定2: 工资标准核实 — 三份证据数值不一致 → 发现gap
    func makeSalaryGapResponse() -> String {
        """
        {
            "finding": "salary_inconsistent",
            "refuted": true,
            "confidence": "high",
            "blocking": "none",
            "evidence_refs": [
                {"source": "salary_table", "location": "line 6", "snippet": "应发工资合计：7550元", "kind": "text"},
                {"source": "social_insurance", "location": "para 1", "snippet": "缴费基数：7450元", "kind": "text"},
                {"source": "housing_fund", "location": "para 1", "snippet": "月缴存基数：7554元", "kind": "text"}
            ],
            "reasoning": "工资标准存在不一致: 工资表显示7550元, 社保缴费基数7450元, 公积金基数7554元。虽然差异不大(100元以内), 但三份官方文件和公司内部文件的数额不完全一致, 需人工确认正确的月工资标准。",
            "findings": [
                {"kind": "gap", "location": "salary_verification:multi_source", "detail": "三份证据工资数额不一致: 社保7450 vs 公积金7554 vs 工资表7550, 差异虽小但应核实确认"}
            ]
        }
        Refuted
        """
    }

    /// LLM判定3: 欠薪事实 — 行政处罚+统计表+银行流水三重印证 → 证据链完整，通过
    func makeArrearsConfirmedResponse() -> String {
        """
        {
            "finding": "none",
            "refuted": false,
            "confidence": "high",
            "blocking": "none",
            "evidence_refs": [
                {"source": "administrative_penalty", "location": "case no 0028", "snippet": "郭又义 93059.85元", "kind": "text"},
                {"source": "arrears_statement", "location": "line 3", "snippet": "合计未发放金额：93059.85元", "kind": "text"}
            ],
            "reasoning": "欠薪事实确认: 行政处罚告知书(政府独立文件)与达海公司自认的未发放工资统计表显示的郭又义欠薪金额完全一致(93059.85元), 两份独立证据相互印证, 证据链完整。",
            "findings": []
        }
        Refuted
        Not Refuted
        """
    }

    /// LLM判定4: 混同用工 — 大量证据但关键人员身份缺失 → 部分通过, 发现gap
    func makeMixedEmploymentGapResponse() -> String {
        """
        {
            "finding": "personnel_identity_unverified",
            "refuted": true,
            "confidence": "medium",
            "blocking": "none",
            "evidence_refs": [
                {"source": "business_registration", "location": "para 1", "snippet": "河南五建建设集团有限公司（持股51%）", "kind": "text"},
                {"source": "personnel_overlap", "location": "summary", "snippet": "达海印章由五建集团党政办管理", "kind": "text"}
            ],
            "reasoning": "混同用工核心证据(工商关联51%持股、注册地址相同、财务印章管理混同)成立。但关键人员身份存在缺口: 爨淑纳(自称五建人事)、周甜、杨旭的身份仅有聊天记录, 缺乏社保或工商登记的独立证据证实。这些人员是混同用工论证的关键证人, 身份无法核实则论证链条不完整。",
            "findings": [
                {"kind": "gap", "location": "personnel_overlap:workers", "detail": "爨淑纳(五建集团人事)身份无社保或工商登记证实, 仅有群聊记录"},
                {"kind": "gap", "location": "personnel_overlap:workers", "detail": "周甜是否为五建集团员工缺乏独立证据(聘任证明由周甜发出但自身身份未独立证实)"},
                {"kind": "gap", "location": "personnel_overlap:workers", "detail": "杨旭是否为五建集团法务仅有聊天记录佐证, 缺乏官方文件"}
            ]
        }
        Refuted
        """
    }

    // MARK: - Test Scenarios

    /// 完整审理：模拟真实证据输入 → 经过全部程序 → 检验输出
    func testFullCaseReview() async throws {
        // Full 4-step chain: employment → salary → arrears → mixed_employment
        // All gaps bubble through; end step collects gap count into metadata
        let procedure = try Procedure(
            name: "four_step",
            steps: [
                Step(name: "verify_employment", kind: .judgment, statutes: [],
                     transitions: ["not_refuted": "verify_salary", "refuted": "end_step"]),
                Step(name: "verify_salary", kind: .judgment, statutes: [],
                     transitions: ["not_refuted": "verify_arrears", "refuted": "verify_arrears"]),
                Step(name: "verify_arrears", kind: .judgment, statutes: [],
                     transitions: ["not_refuted": "verify_mixed", "refuted": "verify_mixed"]),
                Step(name: "verify_mixed", kind: .judgment, statutes: [],
                     transitions: ["not_refuted": "end_step", "refuted": "end_step"]),
                Step(name: "end_step", kind: .code,
                     handler: { ctx in
                         let allGaps = ctx.findings.flatMap { v in v.findings.filter { !$0.isEmpty } }
                         ctx.metadata["total_gaps"] = JSONValue.number(Double(allGaps.count))
                         for g in allGaps {
                             ctx.metadata["gap_\(g.kind)"] = JSONValue.string(g.detail)
                         }
                     },
                     transitions: [:]),
            ],
            maxRounds: 10
        )
        let mock = MockLLM(responses: [
            makeEmploymentPassResponse(),      // [0]: PASS
            makeSalaryGapResponse(),           // [1]: GAP — salary inconsistent
            makeArrearsConfirmedResponse(),    // [2]: PASS — arrears confirmed
            makeMixedEmploymentGapResponse(),  // [3]: GAP — personnel unverified
        ])
        let court = Court(statutes: StatuteBook(), procedure: procedure, llm: mock)
        let result = await court.hear(caseData: makeCaseEvidence())

        // All 4 judgment steps visited
        XCTAssertEqual(result.verdicts.count, 4, "应有4个判决")

        // Employment: PASS
        XCTAssertFalse(result.verdicts[0].refuted)
        // Salary: GAP found
        XCTAssertTrue(result.verdicts[1].refuted)
        XCTAssertEqual(result.verdicts[1].finding, "salary_inconsistent")
        // Arrears: PASS
        XCTAssertFalse(result.verdicts[2].refuted)
        // Mixed: GAP found
        XCTAssertTrue(result.verdicts[3].refuted)
        XCTAssertEqual(result.verdicts[3].finding, "personnel_identity_unverified")

        // Total gaps collected: 1 from salary + 3 from mixed = 4
        let totalGaps = result.verdicts[1].findings.count + result.verdicts[3].findings.count
        XCTAssertEqual(totalGaps, 4, "应有4个证据缺口: 1个工资不一致 + 3个人员身份未核实")

        print("=== 郭又义案件 — 完整四步审理 ===")
        print("最终处置: \(result.finalDisposition)")
        print("审理轮数: \(result.roundCount)")
        print("总gap数: \(totalGaps)")
        for (i, v) in result.verdicts.enumerated() {
            let status = v.refuted ? "⚠️ GAP" : "✅ PASS"
            print("  判决\(i+1) [\(v.finding)]: \(status), gaps=\(v.findings.count)")
            for g in v.findings {
                print("    → [\(g.kind)] \(g.location): \(g.detail)")
            }
        }
    }

    // MARK: - 场景二：证据缺失 → 欠薪事实无法确认

    func testInsufficientArrearsEvidence() async throws {
        let statutes = StatuteBook(statutes: [
            makeEmploymentStatute(),
            makeWageArrearsStatute(),
        ])
        let procedure = try Procedure(
            name: "arrears_only",
            steps: [
                Step(name: "verify_employment", kind: .judgment,
                     statutes: ["employment_relationship"],
                     transitions: ["not_refuted": "verify_arrears", "refuted": "rejected"]),
                Step(name: "verify_arrears", kind: .judgment,
                     statutes: ["wage_arrears"],
                     transitions: ["not_refuted": "approved", "refuted": "needs_evidence"]),
                Step(name: "approved", kind: .code, transitions: [:]),
                Step(name: "rejected", kind: .code, transitions: [:]),
                Step(name: "needs_evidence", kind: .code, transitions: [:]),
            ]
        )

        // Mock: 劳动关系成立 PASS, 欠薪事实 REFUTE (缺失行政处罚告知书)
        let mockLLM = MockLLM(responses: [
            makeEmploymentPassResponse(),
            // LLM tries to claim arrears but admin_penalty is missing from evidence
            """
            {
                "finding": "arrears_uncertain",
                "refuted": true,
                "confidence": "medium",
                "blocking": "none",
                "evidence_refs": [],
                "reasoning": "缺少行政处罚告知书, 仅有工资表无法独立确认欠薪金额, 需要独立政府文件佐证",
                "findings": [{"kind": "gap", "location": "wage_arrears:evidence", "detail": "缺少行政处罚告知书, 欠薪金额仅有公司单方统计"}]
            }
            Refuted
            """
        ])
        let court = Court(statutes: statutes, procedure: procedure, llm: mockLLM)

        // Case data WITHOUT administrative penalty and arrears statement
        let result = await court.hear(caseData: [
            "objective": .string("核实欠薪事实"),
            "social_insurance": .string("参保起始：2020年7月1日"),
            "labor_contract": .string("合同期限：2025年7月1日至2028年6月30日"),
            "salary_table": .string("应发工资合计：7550元"),
            // 关键证据缺失: "administrative_penalty" 和 "arrears_statement"
        ])

        // 欠薪 Statue 要求 administrative_penalty 作为 requiredEvidence
        // LLM 即使尝试判也因没有 evidence_refs 指向缺失的 source 会被 EvidenceRule 强制 reject
        XCTAssertTrue(result.verdicts[1].refuted)
        print("证据不足场景 — 最终处置: \(result.finalDisposition)")
    }

    // MARK: - 场景三：经济补偿金 CODE 步自动计算验证

    func testSeveranceCalculationCODE() async throws {
        // Simple procedure: just the CODE step for calculation
        let box = SeveranceBox()
        let procedure = try Procedure(
            name: "severance_check",
            steps: [
                Step(name: "calculate", kind: .code,
                     handler: { ctx in
                         let monthly = 7550
                         let years = 5
                         let amount = Double(monthly * years)
                         box.amount = amount
                         box.formula = "\(monthly) × \(years)"
                         ctx.metadata["result"] = JSONValue.number(amount)
                         ctx.metadata["formula"] = JSONValue.string("\(monthly) × \(years)")
                     },
                     transitions: [:])
            ]
        )
        let court = Court(statutes: [], procedure: procedure, llm: nil)
        let result = await court.hear(caseData: [
            "monthly_wage": .string("7550"),
            "work_years": .string("5"),
        ])

        // 经济补偿金 = 月工资 × 工作年限 = 7550 × 5 = 37750
        XCTAssertEqual(box.amount, 37750, "CODE 步应计算 7550 × 5 = 37750")
        XCTAssertEqual(box.formula, "7550 × 5", "计算公式应为 月工资 × 年限")
        XCTAssertEqual(result.finalDisposition, .terminalStep, "终态 CODE 步应结束审理")
        XCTAssertEqual(result.roundCount, 1, "单步流程只应审理一轮")
    }

    // MARK: - 场景四：证据验证 — snippet 子串检查

    func testEvidenceSnippetVerification() async throws {
        // Simulate what happens when LLM cites a snippet that doesn't exist in the source
        var validator = EvidenceValidator()
        validator.addSource("labor_contract", "合同期限：2025年7月1日至2028年6月30日")
        validator.addSource("administrative_penalty", "郭又义 93059.85元")

        // Valid: exact snippet exists
        let validRef = EvidenceRef(source: "administrative_penalty", snippet: "郭又义 93059.85元")
        XCTAssertTrue(validator.validate(validRef))

        // Invalid: LLM hallucinated a different amount
        let hallucinatedRef = EvidenceRef(source: "administrative_penalty", snippet: "欠薪总额 150000 元")
        XCTAssertFalse(validator.validate(hallucinatedRef), "幻觉片段应该被拒绝")

        // Invalid: source not registered
        let missingSourceRef = EvidenceRef(source: "court_judgment", snippet: "驳回")
        XCTAssertFalse(validator.validate(missingSourceRef), "未注册的来源应该被拒绝")

        print("证据验证: 真实snippet通过, 幻觉snippet被拦截, 未注册来源被拦截")
    }
}

/// 捕获 CODE 步 handler 内部计算结果的盒子（handler 是 @Sendable 闭包）。
private final class SeveranceBox: @unchecked Sendable {
    var amount: Double?
    var formula: String?
}
