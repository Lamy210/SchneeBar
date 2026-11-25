import AppKit
import SchneeBarCompanionFeature
import Testing

@Test @MainActor func statusImageSurfacePreservesButtonPresentationAndAction() throws {
    let button = NSButton(title: " CPU 42%", target: nil, action: nil)
    let target = NSObject()
    button.target = target
    button.action = #selector(NSButton.performClick(_:))
    button.imagePosition = .imageLeading
    button.toolTip = "CPU 42%"
    button.setAccessibilityLabel("SchneeBar, CPU 42%")
    let baseline = NSImage(size: NSSize(width: 12, height: 12))
    baseline.isTemplate = true
    button.image = baseline
    let original = try #require(button.image)
    let action = button.action
    let surface = CompanionStatusImageSurface()
    let token = surface.begin(on: button)
    #expect(button.image === original)
    let character = NSImage(size: NSSize(width: 18, height: 9))
    #expect(surface.present(character, in: token))
    #expect(button.image?.size == character.size)
    #expect(button.title == " CPU 42%")
    #expect(button.imagePosition == .imageLeading)
    #expect(button.toolTip == "CPU 42%")
    #expect(button.target === target && button.action == action)
    #expect(button.accessibilityLabel() == "SchneeBar, CPU 42%")
    #expect(surface.clear(in: token))
    #expect(button.image === original)
    #expect(button.image?.isTemplate == true)
    #expect(surface.clear(in: token))
    #expect(surface.present(character, in: token))
    surface.end(token)
    #expect(button.image === original)
    #expect(!surface.present(character, in: token))
}

@Test @MainActor func statusImageSurfaceFencesOldSessionsAndRestoresNil() {
    let first = NSButton()
    let second = NSButton()
    first.image = nil
    let original = NSImage(size: NSSize(width: 11, height: 11))
    second.image = original
    let surface = CompanionStatusImageSurface()
    let frame = NSImage(size: NSSize(width: 18, height: 18))
    let a = surface.begin(on: first)
    #expect(surface.present(frame, in: a))
    let b = surface.begin(on: second)
    #expect(first.image == nil)
    #expect(!surface.present(frame, in: a))
    #expect(!surface.clear(in: a))
    surface.end(a)
    #expect(surface.present(frame, in: b))
    surface.stop()
    #expect(second.image === original)
    #expect(!surface.present(frame, in: b))
}

@Test @MainActor func statusImageSurfaceDoesNotClobberExternalReplacement() {
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let surface = CompanionStatusImageSurface()
    let token = surface.begin(on: button)
    let frame = NSImage(size: NSSize(width: 18, height: 9))
    #expect(surface.present(frame, in: token))
    let external = NSImage(size: NSSize(width: 15, height: 15))
    button.image = external
    #expect(!surface.clear(in: token))
    surface.end(token)
    #expect(button.image === external)
    #expect(!surface.present(frame, in: token))
    let next = surface.begin(on: button)
    #expect(surface.present(frame, in: next))
    surface.stop()
    #expect(button.image === external)
}

@Test @MainActor func statusImageSurfaceDoesNotRetainButton() {
    let surface = CompanionStatusImageSurface()
    var button: NSButton? = NSButton()
    weak var weakButton = button
    let token = surface.begin(on: button!)
    button = nil
    #expect(weakButton == nil)
    #expect(!surface.present(NSImage(size: NSSize(width: 18, height: 18)), in: token))
    surface.stop()
}
