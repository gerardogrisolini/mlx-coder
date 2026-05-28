//
//  MLXServerSetupRunnerTests.swift
//  mlx-server
//

import Testing
@testable import MLXServerSetup

@Test
func setupDoubleParserAcceptsDotAndCommaDecimalSeparators() {
    #expect(MLXServerSetupInputParser.parseDouble("1.25") == 1.25)
    #expect(MLXServerSetupInputParser.parseDouble("1,25") == 1.25)
}

@Test
func setupDoubleParserRejectsAmbiguousDecimalSeparators() {
    #expect(MLXServerSetupInputParser.parseDouble("1,2,3") == nil)
    #expect(MLXServerSetupInputParser.parseDouble("1.2.3") == nil)
    #expect(MLXServerSetupInputParser.parseDouble("1,2.3") == nil)
}

@Test
func setupDoubleParserRejectsNonFiniteValues() {
    #expect(MLXServerSetupInputParser.parseDouble("nan") == nil)
    #expect(MLXServerSetupInputParser.parseDouble("inf") == nil)
    #expect(MLXServerSetupInputParser.parseDouble("-inf") == nil)
}

@Test
func setupPathInputLengthValidatorAllowsConfiguredMaximum() {
    let maximum = MLXServerSetupInputParser.maximumPathLength

    #expect(MLXServerSetupInputParser.isValidLength(String(repeating: "a", count: maximum), maximumLength: maximum))
    #expect(!MLXServerSetupInputParser.isValidLength(String(repeating: "a", count: maximum + 1), maximumLength: maximum))
}
