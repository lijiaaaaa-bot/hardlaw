import XCTest
@testable import HardlawKit

/// CompensationCalculator 确定性计算回归测试(goal-driven 生成,独立验证后固化)。
/// 覆盖:加班费三档倍率、加班基数、年休假阶梯、未休年假工资、
/// 经济补偿月数/封顶、违法解除 2N、代通知金 N+1。
final class CompensationCalculatorTests: XCTestCase {

    // MARK: - 加班费(劳动法第44条)

    func testOvertimeWorkday150Percent() {
        let v = CompensationCalculator.overtimePay(monthlySalary: 8000, hours: 10, kind: .workday)
        XCTAssertEqual(v, 689.66, accuracy: 0.5, "8000/21.75/8×10×1.5 ≈ 689.66, got \(v)")
    }

    func testOvertimeRestDay200Percent() {
        let v = CompensationCalculator.overtimePay(monthlySalary: 8000, hours: 8, kind: .restDay)
        XCTAssertEqual(v, 735.63, accuracy: 0.5, "8000/21.75/8×8×2 ≈ 735.63, got \(v)")
    }

    func testOvertimeRestDayCompensatedByLeaveIsZero() {
        let v = CompensationCalculator.overtimePay(monthlySalary: 8000, hours: 8, kind: .restDay, compensatedByLeave: true)
        XCTAssertEqual(v, 0, "休息日加班已补休不支付")
    }

    func testOvertimeStatutoryHoliday300Percent() {
        let v = CompensationCalculator.overtimePay(monthlySalary: 8000, hours: 8, kind: .statutoryHoliday)
        XCTAssertEqual(v, 1103.45, accuracy: 0.5, "8000/21.75/8×8×3 ≈ 1103.45, got \(v)")
    }

    func testOvertimeBaseExcludesWelfareAllowances() {
        let base = CompensationCalculator.overtimeBase(contractSalary: 8000, welfareAllowances: 1500)
        XCTAssertEqual(base, 8000, "加班基数=合同工资,不含福利补贴")
    }

    // MARK: - 年休假(职工带薪年休假条例第3条)

    func testAnnualLeaveTiers() {
        XCTAssertEqual(CompensationCalculator.annualLeaveDays(serviceYears: 5), 5, "满1不满10→5天")
        XCTAssertEqual(CompensationCalculator.annualLeaveDays(serviceYears: 12), 10, "满10不满20→10天")
        XCTAssertEqual(CompensationCalculator.annualLeaveDays(serviceYears: 22), 15, "满20→15天")
        XCTAssertEqual(CompensationCalculator.annualLeaveDays(serviceYears: 0.8), 0, "不满1年→0天")
        XCTAssertEqual(CompensationCalculator.annualLeaveDays(serviceYears: 10), 10, "恰满10年→10天")
    }

    func testUnusedAnnualLeavePay200PercentExtra() {
        let v = CompensationCalculator.unusedAnnualLeavePay(monthlySalary: 8000, unusedDays: 5)
        XCTAssertEqual(v, 3678.16, accuracy: 5, "8000/21.75×2×5 ≈ 3678.16, got \(v)")
    }

    // MARK: - 经济补偿(劳动合同法第47条)

    func testSeveranceMonths() {
        XCTAssertEqual(CompensationCalculator.severanceMonths(years: 2.4), 2.5, accuracy: 0.001)
        XCTAssertEqual(CompensationCalculator.severanceMonths(years: 5.8), 6, accuracy: 0.001)
        XCTAssertEqual(CompensationCalculator.severanceMonths(years: 0.4), 0.5, accuracy: 0.001)
        XCTAssertEqual(CompensationCalculator.severanceMonths(years: 5.0), 5, accuracy: 0.001, "整年不加 0.5")
        XCTAssertEqual(CompensationCalculator.severanceMonths(years: 0.5), 1, accuracy: 0.001, "六个月以上按一年")
        XCTAssertEqual(CompensationCalculator.severanceMonths(years: 6.5), 7, accuracy: 0.001)
    }

    func testSeveranceAmountHighSalaryCapped() {
        // 月薪 50000 > 社平 3 倍(30000)→ 基数封顶 30000、年限封顶 12 年
        let v = CompensationCalculator.severanceAmount(monthlySalary: 50000, years: 20, averageSocialSalary: 10000)
        XCTAssertEqual(v, 360000, "30000×12=360000, got \(v)")
    }

    func testSeveranceAmountNormal() {
        let v = CompensationCalculator.severanceAmount(monthlySalary: 8000, years: 3, averageSocialSalary: 10000)
        XCTAssertEqual(v, 24000, "8000×3=24000, got \(v)")
    }

    // MARK: - 违法解除赔偿(第87条)与代通知金(第40条)

    func testUnlawfulTerminationPay2N() {
        let v = CompensationCalculator.unlawfulTerminationPay(monthlySalary: 8000, years: 3, averageSocialSalary: 10000)
        XCTAssertEqual(v, 48000, "24000×2=48000, got \(v)")
    }

    func testPaymentInLieuNPlusOne() {
        let v = CompensationCalculator.paymentInLieu(monthlySalary: 8000)
        XCTAssertEqual(v, 8000, "代通知金=上月工资 1 个月")
    }
}
