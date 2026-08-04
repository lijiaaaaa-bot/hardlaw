import SwiftUI

/// 新建案件 — 填写案由、当事人、仲裁请求
struct CaseIntakeView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var caseName = ""
    @State private var applicant = ""
    @State private var respondent = ""
    @State private var claims: [ClaimDraft] = [ClaimDraft(number: 1)]

    let onSave: (CaseFile) -> Void

    /// 常用案由快速选择
    static let commonCaseTypes = [
        "拖欠工资、被迫解除劳动合同",
        "拖欠工资、主张经济补偿金",
        "未签书面合同、双倍工资",
        "违法解除劳动合同、赔偿金",
        "工伤待遇争议",
        "确认劳动关系",
    ]

    /// 常用法律依据快速选择
    static let commonLawBases = [
        "《劳动合同法》第38条",
        "《劳动合同法》第46条",
        "《劳动合同法》第47条",
        "《劳动合同法》第82条",
        "《劳动合同法》第85条",
        "《劳动合同法》第87条",
        "《劳动争议调解仲裁法》第6条",
        "《劳动争议调解仲裁法》第27条",
    ]

    var body: some View {
        NavigationStack {
            Form {
                // 案由
                Section("案由") {
                    Picker("案件类型", selection: $caseName) {
                        Text("请选择").tag("")
                        ForEach(Self.commonCaseTypes, id: \.self) { t in
                            Text(t).tag(t)
                        }
                    }
                    .pickerStyle(.menu)

                    if !caseName.isEmpty {
                        Text(caseName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 当事人
                Section("当事人信息") {
                    TextField("申请人（劳动者）", text: $applicant)
                    TextField("被申请人（用人单位）", text: $respondent)
                }

                // 仲裁请求
                Section {
                    ForEach($claims) { $claim in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("请求 \(claim.number)")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.blue)
                                Spacer()
                                if claims.count > 1 {
                                    Button("删除") {
                                        claims.removeAll { $0.id == claim.id }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                }
                            }

                            TextField("请求内容，如：请求裁决被申请人支付拖欠工资...", text: $claim.content, axis: .vertical)
                                .font(.callout)
                                .lineLimit(2...4)

                            Picker("法律依据", selection: $claim.legalBasis) {
                                Text("选择法律依据").tag("")
                                ForEach(Self.commonLawBases, id: \.self) { law in
                                    Text(law).tag(law)
                                }
                            }
                            .pickerStyle(.menu)
                            .font(.caption)

                            if !claim.legalBasis.isEmpty {
                                Text(claim.legalBasis)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }



                        }
                        .padding(.vertical, 4)
                    }

                    Button {
                        claims.append(ClaimDraft(number: claims.count + 1))
                    } label: {
                        Label("添加仲裁请求", systemImage: "plus.circle")
                            .font(.callout)
                    }
                } header: {
                    Text("仲裁请求事项")
                } footer: {
                    Text("至少填写一项仲裁请求。证据核查将围绕你的请求展开。")
                }
            }
            .navigationTitle("新建案件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        let caseFile = CaseFile(
                            caseName: caseName,
                            applicant: applicant,
                            respondent: respondent,
                            claims: claims.compactMap { draft in
                                guard !draft.content.isEmpty else { return nil }
                                return ClaimItem(
                                    claimNumber: draft.number,
                                    content: draft.content,
                                    legalBasis: draft.legalBasis
                                )
                            }
                        )
                        onSave(caseFile)
                    }
                    .fontWeight(.semibold)
                    .disabled(caseName.isEmpty || applicant.isEmpty || respondent.isEmpty || claims.allSatisfy { $0.content.isEmpty })
                }
            }
        }
    }
}

/// 草稿 — 用于表单绑定的临时数据
@Observable
class ClaimDraft: Identifiable {
    let id = UUID()
    var number: Int
    var content = ""
    var legalBasis = ""

    init(number: Int) {
        self.number = number
    }
}
