import Foundation
import SwiftUI

// MARK: - 案件实体

/// 一个劳动争议案件档案
@Observable
public final class CaseFile: Identifiable {
    public let id: UUID
    public var caseName: String           // 案由，如"拖欠工资、被迫解除劳动合同"
    public var applicant: String          // 申请人
    public var respondent: String         // 被申请人
    public var createdAt: Date
    public var claims: [ClaimItem]        // 仲裁请求列表
    public var evidenceItems: [EvidenceItem]  // 证据目录
    public var gaps: [GapItem]            // 待核实问题
    public var stage: CaseStage

    public init(
        caseName: String = "",
        applicant: String = "",
        respondent: String = "",
        claims: [ClaimItem] = [],
        evidenceItems: [EvidenceItem] = [],
        stage: CaseStage = .drafting
    ) {
        self.id = UUID()
        self.caseName = caseName
        self.applicant = applicant
        self.respondent = respondent
        self.createdAt = Date()
        self.claims = claims
        self.evidenceItems = evidenceItems
        self.stage = stage
        self.gaps = []
    }
}

public enum CaseStage: String, CaseIterable, Sendable {
    case drafting = "起草"
    case evidenceCollection = "证据收集"
    case catalogReview = "目录审查"
    case gapResolution = "补证"
    case readyToFile = "可提交"
}

// MARK: - 仲裁请求

@Observable
public final class ClaimItem: Identifiable {
    public let id: UUID
    public var claimNumber: Int           // 请求序号
    public var content: String            // 请求内容
    public var legalBasis: String         // 法律依据

    public init(
        claimNumber: Int = 0,
        content: String = "",
        legalBasis: String = ""
    ) {
        self.id = UUID()
        self.claimNumber = claimNumber
        self.content = content
        self.legalBasis = legalBasis
    }
}

// MARK: - 证据项（七列目录）

@Observable
public final class EvidenceItem: Identifiable {
    public let id: UUID
    public var group: String             // 组别
    public var number: Int               // 编号
    public var name: String              // 证据名称
    public var isOriginal: Bool          // 原件/复印件
    public var pageCount: Int            // 页码
    public var proofContent: String      // 证明内容（AI 自动生成草稿）
    public var proofPurpose: String      // 证明目的（AI 自动生成草稿）
    public var sourceOCRText: String     // Vision OCR 提取的源文件文字
    public var verificationStatus: VerificationStatus

    public init(
        group: String = "",
        number: Int = 0,
        name: String = "",
        isOriginal: Bool = true,
        pageCount: Int = 1,
        proofContent: String = "",
        proofPurpose: String = "",
        sourceOCRText: String = "",
        verificationStatus: VerificationStatus = .unverified
    ) {
        self.id = UUID()
        self.group = group
        self.number = number
        self.name = name
        self.isOriginal = isOriginal
        self.pageCount = pageCount
        self.proofContent = proofContent
        self.proofPurpose = proofPurpose
        self.sourceOCRText = sourceOCRText
        self.verificationStatus = verificationStatus
    }
}

public enum VerificationStatus: String, CaseIterable, Sendable {
    case unverified = "未验证"
    case verified = "已验证通过"
    case inconsistent = "内容不一致"
    case needsReview = "需人工复核"
}

// MARK: - 证据缺口

@Observable
public final class GapItem: Identifiable {
    public let id: UUID
    public var severity: GapSeverity
    public var description: String       // 缺口描述
    public var suggestedRemedy: String   // 补证建议
    public var relatedClaim: String      // 关联的仲裁请求
    public var isResolved: Bool

    public init(
        severity: GapSeverity = .medium,
        description: String = "",
        suggestedRemedy: String = "",
        relatedClaim: String = "",
        isResolved: Bool = false
    ) {
        self.id = UUID()
        self.severity = severity
        self.description = description
        self.suggestedRemedy = suggestedRemedy
        self.relatedClaim = relatedClaim
        self.isResolved = isResolved
    }
}

public enum GapSeverity: String, CaseIterable, Sendable {
    case critical = "严重"
    case high = "重要"
    case medium = "一般"
    case low = "轻微"
}
