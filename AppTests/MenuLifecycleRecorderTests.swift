import Testing

@testable import Usage

@Test("A fresh recorder is balanced with no observed transitions")
func freshRecorderIsBalanced() {
    let recorder = MenuLifecycleRecorder()
    #expect(recorder.appearances == 0)
    #expect(recorder.disappearances == 0)
    #expect(recorder.isBalanced)
}

@Test("An appearance without its matching disappearance is unbalanced")
func pendingAppearanceIsUnbalanced() {
    let recorder = MenuLifecycleRecorder()
    recorder.recordAppear()
    #expect(recorder.appearances == 1)
    #expect(recorder.disappearances == 0)
    #expect(!recorder.isBalanced)
}

@Test("Ten open/close cycles produce ten balanced transitions")
func repeatedCyclesStayBalanced() {
    let recorder = MenuLifecycleRecorder()
    for _ in 0..<10 {
        recorder.recordAppear()
        recorder.recordDisappear()
    }
    #expect(recorder.appearances == 10)
    #expect(recorder.disappearances == 10)
    #expect(recorder.isBalanced)
}

@Test("A duplicated disappearance is reported as unbalanced rather than clamped")
func duplicateDisappearanceIsUnbalanced() {
    let recorder = MenuLifecycleRecorder()
    recorder.recordAppear()
    recorder.recordDisappear()
    recorder.recordDisappear()
    #expect(recorder.appearances == 1)
    #expect(recorder.disappearances == 2)
    #expect(!recorder.isBalanced)
}
