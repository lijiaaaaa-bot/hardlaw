import Foundation

// MARK: - OvertimeKind

/// 加班类型(劳动法第44条)
public enum OvertimeKind: Sendable {
    case workday        // 工作日延长工作时间 → 150%
    case restDay        // 休息日安排工作 → 200%(可补休)
    case statutoryHoliday // 法定休假日 → 300%
}

// MARK: - CompensationCalculator

/// 劳动报酬确定性计算器(《劳动合同法》第44/47/82/85/87条、《职工带薪年休假条例》第5条)。
/// 全部为纯函数、确定性、无 LLM —— 数字由代码计算,LLM 只负责提取输入。
public enum CompensationCalculator {

    /// 月计薪天数(劳社部发〔2008〕3号): (365-104)/12 ≈ 21.75
    public static let monthlyWorkingDays: Double = 21.75
    /// 每日标准工时
    public static let dailyWorkingHours: Double = 8

    // MARK: - 加班费(劳动法第44条)

    /// 加班费计算基数: 劳动合同约定的工资标准,不含福利性补贴。
    public static func overtimeBase(contractSalary: Double, welfareAllowances: Double) -> Double {
        contractSalary
    }

    /// 加班费 = 时薪 × 小时数 × 倍率;休息日已补休则支付 0。
    /// 时薪 = 基数 / 21.75 / 8。
    ///
    /// 倍率(劳动法第44条): 工作日 1.5、休息日 2.0、法定节假日 3.0。
    public static func overtimePay(monthlySalary: Double, hours: Double, kind: OvertimeKind, compensatedByLeave: Bool = false) -> Double {
        if kind == .restDay && compensatedByLeave {
            return 0
        }

        let hourlyRate = monthlySalary / monthlyWorkingDays / dailyWorkingHours
        let multiplier: Double
        switch kind {
        case .workday:
            multiplier = 1.5
        case .restDay:
            multiplier = 2.0
        case .statutoryHoliday:
            multiplier = 3.0
        }

        return hourlyRate * hours * multiplier
    }

    // MARK: - 年休假(职工带薪年休假条例第3条)

    /// 年休假天数: 满1年不满10年→5天;满10年不满20年→10天;满20年→15天。
    public static func annualLeaveDays(serviceYears: Double) -> Int {
        if serviceYears >= 20 {
            return 15
        } else if serviceYears >= 10 {
            return 10
        } else if serviceYears >= 1 {
            return 5
        } else {
            return 0
        }
    }

    /// 未休年休假工资: 日工资 × 200% × 未休天数(条例第5条第3款,300%含正常工资,额外 200%)。
    public static func unusedAnnualLeavePay(monthlySalary: Double, unusedDays: Int) -> Double {
        let dailyWage = monthlySalary / monthlyWorkingDays
        return dailyWage * 2.0 * Double(unusedDays)
    }

    // MARK: - 经济补偿(劳动合同法第47条)

    /// 经济补偿月数: 每满一年一个月;六个月以上不满一年按一年;不满六个月半个月。
    public static func severanceMonths(years: Double) -> Double {
        let fullYears = floor(years)
        let remainder = years - fullYears

        if remainder == 0 {
            return fullYears
        } else if remainder < 0.5 {
            return fullYears + 0.5
        } else {
            return fullYears + 1.0
        }
    }

    /// 经济补偿金: 月工资×月数;高薪(>社平3倍)封顶基数=社平3倍、封顶12年。
    public static func severanceAmount(monthlySalary: Double, years: Double, averageSocialSalary: Double) -> Double {
        let socialCap = averageSocialSalary * 3.0

        let baseSalary: Double
        let months: Double

        if monthlySalary > socialCap {
            baseSalary = socialCap
            months = min(severanceMonths(years: years), 12.0)
        } else {
            baseSalary = monthlySalary
            months = severanceMonths(years: years)
        }

        return baseSalary * months
    }

    // MARK: - 违法解除赔偿(劳动合同法第87条)

    /// 违法解除赔偿金 = 经济补偿 × 2(2N)。
    public static func unlawfulTerminationPay(monthlySalary: Double, years: Double, averageSocialSalary: Double) -> Double {
        return severanceAmount(monthlySalary: monthlySalary, years: years, averageSocialSalary: averageSocialSalary) * 2.0
    }

    // MARK: - 代通知金(劳动合同法第40条)

    /// 代通知金 = 上月工资 1 个月(N+1 里的 +1)。
    public static func paymentInLieu(monthlySalary: Double) -> Double {
        return monthlySalary
    }
}
