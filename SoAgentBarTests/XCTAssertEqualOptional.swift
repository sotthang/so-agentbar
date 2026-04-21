import XCTest

/// XCTAssertEqual(_:_:accuracy:) 의 Optional<T: FloatingPoint> 오버로드.
/// `monitor.metrics?.cpuPercent` 처럼 optional chaining 결과를 accuracy 비교할 때 사용.
public func XCTAssertEqual<T: FloatingPoint>(
    _ expression1: T?,
    _ expression2: T,
    accuracy: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let value = expression1 else {
        XCTFail("XCTAssertEqual failed: expression1 is nil\(message().isEmpty ? "" : " — \(message())")",
                file: file, line: line)
        return
    }
    XCTAssertEqual(value, expression2, accuracy: accuracy, message(), file: file, line: line)
}
