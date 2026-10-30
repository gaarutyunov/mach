const std = @import("std");
const mach = @import("../main.zig");
const Core = @import("../Core.zig");
const gpu = mach.gpu;
const Event = Core.Event;
const KeyEvent = Core.Event.Key;
const MouseButtonEvent = Core.Event.MouseButton;
const MouseButton = Core.MouseButtonID;
const Size = Core.Size;
const DisplayMode = Core.DisplayMode;
const CursorShape = Core.CursorShape;
const VSyncMode = Core.VSyncMode;
const Position = Core.Position;
const Key = Core.KeyButtonID;
const KeyMods = Core.KeyMods;
const objc = @import("objc");
const metal = @import("../sysgpu/metal.zig");

const log = std.log.scoped(.mach);

pub const Darwin = @This();

/// NSObject subclass implementing NSApplicationDelegate.
const MACHAppDelegate = objc.objc.DefineClass(struct {
    pub const class_name = "MACHAppDelegate";
    pub const superclass = objc.foundation.ObjectInterface;
    pub const protocols = &.{objc.app_kit.ApplicationDelegate};

    pub const Self = objc.objc.Self(class_name);

    pub const methods = struct {
        /// Called by AppKit once at the start of `NSApp.run()`. Kicks off the very first main
        /// tick synchronously on the main thread; subsequent ticks are driven by `wakeMainThread`.
        pub fn @"applicationDidFinishLaunching:"(_: *Self, _: ?*objc.app_kit.Notification) void {
            if (main_tick_fn) |f| f(main_tick_ctx);
        }

        pub fn @"applicationShouldTerminate:"(_: *Self, _: ?*objc.app_kit.Application) usize {
            return 0; // NSTerminateCancel
        }

        pub fn @"applicationShouldTerminateAfterLastWindowClosed:"(_: *Self, _: ?*objc.app_kit.Application) bool {
            return true;
        }
    };
});

/// NSObject subclass implementing NSWindowDelegate.
const MACHWindowDelegate = objc.objc.DefineClass(struct {
    pub const class_name = "MACHWindowDelegate";
    pub const superclass = objc.foundation.ObjectInterface;
    pub const protocols = &.{objc.app_kit.WindowDelegate};

    pub const Self = objc.objc.Self(class_name);

    pub const implementation = objc.objc.implementation(class_name, struct {
        _state: *anyopaque, // -> *NativeState
    });

    fn state(d: *Self) *NativeState {
        return @ptrCast(@alignCast(implementation._state.get(d).?));
    }

    /// Handles a potential window resize, framebuffer resize, or DPI change. Called from the
    /// windowDidResize and windowDidChangeBackingProperties IMPs.
    fn handleResize(n: *NativeState) void {
        n.core.windows.lock();
        defer n.core.windows.unlock();

        const core_window = n.core.windows.getValue(n.window_id);

        // Determine the current width / height / pixel density of the window.
        const frame = n.window.frame();
        const content_rect = n.window.contentRectForFrameRect(frame);
        const width: u32 = @intFromFloat(content_rect.size.width);
        const height: u32 = @intFromFloat(content_rect.size.height);
        const pixel_density: f32 = @floatCast(n.window.backingScaleFactor());

        // Skip the work if nothing actually changed (handleResize can be called for many reasons.)
        if (core_window.width == width and
            core_window.height == height and
            core_window.pixel_density == pixel_density) return;

        const fb_width: u32 = @intFromFloat(@as(f32, @floatFromInt(width)) * pixel_density);
        const fb_height: u32 = @intFromFloat(@as(f32, @floatFromInt(height)) * pixel_density);

        // Queue a swap chain recreation for the render thread.
        n.pending_swap_chain_update = .{
            .width = width,
            .height = height,
            .framebuffer_width = fb_width,
            .framebuffer_height = fb_height,
            .pixel_density = pixel_density,
            .vsync_mode = core_window.vsync_mode,
        };

        n.core.pushEvent(.{ .resize = .{
            .window_id = n.window_id,
            .window_size = .{ .width = width, .height = height },
            .framebuffer_size = .{ .width = fb_width, .height = fb_height },
            .pixel_density = pixel_density,
        } });
    }

    pub const methods = struct {
        /// Called by AppKit when the user clicks the window's close button.
        pub fn @"windowShouldClose:"(self: *Self, _: ?*objc.app_kit.Window) bool {
            const n = state(self);
            n.core.pushEvent(.{ .close = .{ .window_id = n.window_id } });
            return false;
        }

        /// Called by AppKit when the window becomes key (focused).
        pub fn @"windowDidBecomeKey:"(self: *Self, _: ?*objc.app_kit.Notification) void {
            const n = state(self);
            n.core.pushEvent(.{ .focus_gained = .{ .window_id = n.window_id } });
        }

        /// Called by AppKit when the window resigns key (loses focus). Auto-releases mouse
        /// capture.
        pub fn @"windowDidResignKey:"(self: *Self, _: ?*objc.app_kit.Notification) void {
            const n = state(self);
            if (n.mouse_captured) {
                n.core.windows.lock();
                disableMouseCapture(n, false);
                n.core.windows.unlock();
            }
            n.core.pushEvent(.{ .focus_lost = .{ .window_id = n.window_id } });
        }

        /// Called by AppKit when the user resizes the window.
        pub fn @"windowDidResize:"(self: *Self, _: ?*objc.app_kit.Notification) void {
            handleResize(state(self));
        }

        /// Called by AppKit when the window's backing scale factor changes (e.g. when the
        /// window is dragged between displays of different DPI). In this case the framebuffer
        /// size has changed so we need to consider it as a potential resize event.
        pub fn @"windowDidChangeBackingProperties:"(self: *Self, _: ?*objc.app_kit.Notification) void {
            handleResize(state(self));
        }
    };
});

/// NSView subclass implementing CAMetalDisplayLinkDelegate.
const MACHView = objc.objc.DefineClass(struct {
    pub const class_name = "MACHView";
    pub const superclass = objc.app_kit.View;

    pub const Self = objc.objc.Self(class_name);

    pub const implementation = objc.objc.implementation(class_name, struct {
        _state: *anyopaque, // -> *NativeState
        trackingArea: objc.objc.StrongObject("NSTrackingArea"),
        _displayLink: objc.objc.StrongObject("CAMetalDisplayLink"),
    });

    fn state(v: *Self) *NativeState {
        return @ptrCast(@alignCast(implementation._state.get(v).?));
    }

    /// Pushes a `mouse_motion` event with `event`'s window-relative position, OR a
    /// `mouse_motion_relative` event with raw NSEvent deltas if the window currently has
    /// mouse capture. Shared by all the mouse{Moved,Dragged,rightMouseDragged,otherMouseDragged}
    /// IMPs.
    fn pushMouseMotion(n: *NativeState, event: *objc.app_kit.Event) void {
        // While captured, the on-screen cursor is frozen and the cursor's window-relative
        // position is meaningless. NSEvent deltaX/deltaY continue to report raw mouse motion
        // even while CGAssociateMouseAndMouseCursorPosition is disabled.
        if (n.mouse_captured) {
            if (n.suppress_next_capture_motion) {
                n.suppress_next_capture_motion = false;
                return;
            }
            n.core.pushEvent(.{ .mouse_motion_relative = .{
                .window_id = n.window_id,
                .dx = objc.objc.msgSend(event, "deltaX", f64, .{}),
                .dy = objc.objc.msgSend(event, "deltaY", f64, .{}),
            } });
            return;
        }
        const mouse_location = event.locationInWindow();
        n.core.windows.lockShared();
        const window_height: f32 = @floatFromInt(n.core.windows.get(n.window_id, .height));
        n.core.windows.unlockShared();
        n.core.pushEvent(.{ .mouse_motion = .{
            .window_id = n.window_id,
            .pos = .{ .x = mouse_location.x, .y = window_height - mouse_location.y },
        } });
    }

    /// Pushes a `mouse_press` event. Shared by `mouseDown:`, `rightMouseDown:`, `otherMouseDown:`.
    fn pushMousePress(n: *NativeState, event: *objc.app_kit.Event) void {
        n.core.pushEvent(.{ .mouse_press = .{
            .window_id = n.window_id,
            .button = @fromBackingInt(@intCast(event.buttonNumber())),
            .pos = .{ .x = event.locationInWindow().x, .y = event.locationInWindow().y },
            .mods = machModifierFromModifierFlag(event.modifierFlags()),
        } });
    }

    /// Pushes a `mouse_release` event. Shared by `mouseUp:`, `rightMouseUp:`, `otherMouseUp:`.
    fn pushMouseRelease(n: *NativeState, event: *objc.app_kit.Event) void {
        n.core.pushEvent(.{ .mouse_release = .{
            .window_id = n.window_id,
            .button = @fromBackingInt(@intCast(event.buttonNumber())),
            .pos = .{ .x = event.locationInWindow().x, .y = event.locationInWindow().y },
            .mods = machModifierFromModifierFlag(event.modifierFlags()),
        } });
    }

    pub const methods = struct {
        /// Overrides NSView's designated initializer to install a tracking area covering the
        /// view's visible rect, so we receive mouseEntered/Exited and mouseMoved callbacks.
        pub fn @"initWithFrame:"(old_self: *Self, frame: objc.app_kit.Rect) ?*Self {
            const super = objc.objc.superFn(objc.app_kit.View, "initWithFrame:", fn (*Self, objc.app_kit.Rect) ?*Self);
            const self = super(old_self, frame) orelse return null;

            const opts: objc.app_kit.TrackingAreaOptions =
                objc.app_kit.TrackingMouseEnteredAndExited |
                objc.app_kit.TrackingMouseMoved |
                objc.app_kit.TrackingActiveInActiveApp;
            const rect = objc.app_kit.View.visibleRect(@ptrCast(self));
            const tracking = objc.app_kit.TrackingArea.alloc().initWithRect_options_owner_userInfo(
                rect,
                opts,
                @ptrCast(self),
                null,
            );
            // Take ownership of the +1 retained tracking area into the
            // strong ivar slot (no extra retain).
            const slot = implementation.trackingArea.slot(self) orelse return self;
            slot.* = @ptrCast(tracking);

            objc.app_kit.View.addTrackingArea(@ptrCast(self), tracking);
            return self;
        }

        pub fn canBecomeKeyView(_: *Self) bool {
            return true;
        }

        pub fn acceptsFirstResponder(_: *Self) bool {
            return true;
        }

        /// Prevent AppKit's default key handling (e.g. Esc exiting fullscreen) from firing.
        pub fn @"doCommandBySelector:"(_: *Self, _: ?*objc.objc.Selector) void {}

        /// Pushes a `key_press` or `key_repeat` event, then forwards the event through
        /// `interpretKeyEvents:` so AppKit can turn it into an `insertText:` call where
        /// appropriate.
        pub fn @"keyDown:"(self: *Self, event: ?*objc.app_kit.Event) void {
            const n = state(self);
            const e = event.?;
            if (e.isARepeat()) {
                n.core.pushEvent(.{ .key_repeat = .{
                    .window_id = n.window_id,
                    .key = machKeyFromKeycode(e.keyCode()),
                    .mods = machModifierFromModifierFlag(e.modifierFlags()),
                } });
            } else {
                n.core.pushEvent(.{ .key_press = .{
                    .window_id = n.window_id,
                    .key = machKeyFromKeycode(e.keyCode()),
                    .mods = machModifierFromModifierFlag(e.modifierFlags()),
                } });
            }
            // [self interpretKeyEvents:[NSArray arrayWithObject:event]]
            const arr = objc.foundation.Array(objc.app_kit.Event).arrayWithObject(e);
            objc.app_kit.Responder.interpretKeyEvents(@ptrCast(self), @ptrCast(arr));
        }

        /// Pushes a `key_release` event.
        pub fn @"keyUp:"(self: *Self, event: ?*objc.app_kit.Event) void {
            const n = state(self);
            const e = event.?;
            n.core.pushEvent(.{ .key_release = .{
                .window_id = n.window_id,
                .key = machKeyFromKeycode(e.keyCode()),
                .mods = machModifierFromModifierFlag(e.modifierFlags()),
            } });
        }

        /// Called when one of the modifier keys (shift, control, option, command, caps lock)
        /// changes state. AppKit doesn't distinguish press from release for modifiers, so we
        /// infer the transition by combining the new flag bitmask with `input_state`.
        pub fn @"flagsChanged:"(self: *Self, event: ?*objc.app_kit.Event) void {
            const n = state(self);
            const e = event.?;
            const key = machKeyFromKeycode(e.keyCode());
            const mods = machModifierFromModifierFlag(e.modifierFlags());
            const key_flag = switch (key) {
                .left_shift, .right_shift => objc.app_kit.EventModifierFlagShift,
                .left_control, .right_control => objc.app_kit.EventModifierFlagControl,
                .left_alt, .right_alt => objc.app_kit.EventModifierFlagOption,
                .left_super, .right_super => objc.app_kit.EventModifierFlagCommand,
                .caps_lock => objc.app_kit.EventModifierFlagCapsLock,
                else => 0,
            };

            if (e.modifierFlags() & key_flag != 0) {
                if (n.core.input_state.keyPressed(key)) {
                    n.core.pushEvent(.{ .key_release = .{ .window_id = n.window_id, .key = key, .mods = mods } });
                } else {
                    n.core.pushEvent(.{ .key_press = .{ .window_id = n.window_id, .key = key, .mods = mods } });
                }
            } else {
                n.core.pushEvent(.{ .key_release = .{ .window_id = n.window_id, .key = key, .mods = mods } });
            }
        }

        pub fn @"mouseMoved:"(self: *Self, event: ?*objc.app_kit.Event) void {
            pushMouseMotion(state(self), event.?);
        }
        pub fn @"mouseDragged:"(self: *Self, event: ?*objc.app_kit.Event) void {
            pushMouseMotion(state(self), event.?);
        }
        pub fn @"rightMouseDragged:"(self: *Self, event: ?*objc.app_kit.Event) void {
            pushMouseMotion(state(self), event.?);
        }
        pub fn @"otherMouseDragged:"(self: *Self, event: ?*objc.app_kit.Event) void {
            pushMouseMotion(state(self), event.?);
        }

        pub fn @"mouseDown:"(self: *Self, event: ?*objc.app_kit.Event) void {
            pushMousePress(state(self), event.?);
        }
        pub fn @"rightMouseDown:"(self: *Self, event: ?*objc.app_kit.Event) void {
            pushMousePress(state(self), event.?);
        }
        pub fn @"otherMouseDown:"(self: *Self, event: ?*objc.app_kit.Event) void {
            pushMousePress(state(self), event.?);
        }

        pub fn @"mouseUp:"(self: *Self, event: ?*objc.app_kit.Event) void {
            pushMouseRelease(state(self), event.?);
        }
        pub fn @"rightMouseUp:"(self: *Self, event: ?*objc.app_kit.Event) void {
            pushMouseRelease(state(self), event.?);
        }
        pub fn @"otherMouseUp:"(self: *Self, event: ?*objc.app_kit.Event) void {
            pushMouseRelease(state(self), event.?);
        }

        /// Pushes a `mouse_scroll` event. Trackpad scrolls report precise pixel deltas, which
        /// we scale down to roughly match the line-based units of a wheel scroll.
        pub fn @"scrollWheel:"(self: *Self, event: ?*objc.app_kit.Event) void {
            const n = state(self);
            const e = event.?;
            var scroll_delta_x = e.scrollingDeltaX();
            var scroll_delta_y = e.scrollingDeltaY();
            if (e.hasPreciseScrollingDeltas()) {
                scroll_delta_x *= 0.1;
                scroll_delta_y *= 0.1;
            }
            n.core.pushEvent(.{ .mouse_scroll = .{
                .window_id = n.window_id,
                .xoffset = @floatCast(scroll_delta_x),
                .yoffset = @floatCast(scroll_delta_y),
            } });
        }

        /// Pushes a `zoom_gesture` event. e.g. fired on macOS using a trackpad pinch.
        pub fn @"magnifyWithEvent:"(self: *Self, event: ?*objc.app_kit.Event) void {
            const n = state(self);
            const e = event.?;
            n.core.pushEvent(.{ .zoom_gesture = .{
                .window_id = n.window_id,
                .zoom = @floatCast(e.magnification()),
                .phase = machPhaseFromPhase(e.phase()),
            } });
        }

        /// Called by AppKit (via `interpretKeyEvents:` invoked from `keyDown:`) to deliver
        /// composed/translated text input. Walks the (possibly attributed) string codepoint by
        /// codepoint and pushes one `char_input` event per codepoint, skipping AppKit's
        /// private-use function-key codes (arrows etc.).
        pub fn @"insertText:"(self: *Self, string: ?*objc.foundation.String) void {
            const n = state(self);

            // Unwrap NSAttributedString → NSString if needed.
            const characters: ?*objc.foundation.String = blk: {
                if (objc.objc.isKindOf(string, objc.foundation.AttributedString)) {
                    const attr: *objc.foundation.AttributedString = @ptrCast(string.?);
                    break :blk attr.string();
                }
                break :blk string;
            };
            const chars = characters orelse return;

            var range: objc.foundation.Range = .init(0, chars.length());
            while (range.length > 0) {
                var codepoint: u32 = 0;
                const got = chars.getBytes_maxLength_usedLength_encoding_options_range_remainingRange(
                    @ptrCast(&codepoint),
                    @sizeOf(u32),
                    null,
                    objc.foundation.UTF32StringEncoding,
                    0,
                    range,
                    &range,
                );
                if (!got) break;
                if (codepoint >= 0xf700 and codepoint <= 0xf7ff) continue;
                n.core.pushEvent(.{ .char_input = .{ .codepoint = @intCast(codepoint), .window_id = n.window_id } });
            }
        }

        /// CAMetalDisplayLinkDelegate callback invoked on every vsync. Forwards the new
        /// drawable to `displayLinkWake` via the view's `*NativeState` ivar. Gated by
        /// `surface.use_display_link` to drop in-flight callbacks that race with detach.
        pub fn @"metalDisplayLink:needsUpdate:"(
            self: *Self,
            _: ?*objc.quartz_core.MetalDisplayLink, // unused
            update: ?*objc.quartz_core.MetalDisplayLinkUpdate,
        ) void {
            const u = update orelse return;
            const n = state(self);
            if (!@atomicLoad(bool, &n.surface.use_display_link, .acquire)) return;
            displayLinkWake(n, u.drawable());
        }
    };

    pub const direct_methods = struct {
        /// Start driving rendering off a CAMetalDisplayLink, so `metalDisplayLink:needsUpdate:`
        /// fires on every vsync.
        pub fn startDisplayLink(self: *Self) callconv(.c) bool {
            if (implementation._displayLink.get(self) != null) return true;
            // CAMetalDisplayLink requires macOS 14+; fall back to a render thread when unavailable.
            if (objc.quartz_core.MetalDisplayLink.InternalInfo.classOrNull() == null) return false;

            const base_layer = objc.app_kit.View.layer(@ptrCast(self));
            if (!objc.objc.isKindOf(base_layer, objc.quartz_core.MetalLayer)) return false;
            const metal_layer: *objc.quartz_core.MetalLayer = @ptrCast(base_layer);

            const link = objc.quartz_core.MetalDisplayLink.alloc().initWithMetalLayer(metal_layer);
            // Take ownership of the +1 retained `link` directly into the
            // ivar slot (no extra retain). Subsequent `set(self, …)` calls
            // would balance through `objc_storeStrong`.
            const slot = implementation._displayLink.slot(self) orelse return false;
            slot.* = link;

            link.setDelegate(@ptrCast(self));
            link.addToRunLoop_forMode(objc.foundation.RunLoop.mainRunLoop(), objc.app_kit.NSRunLoopCommonModes);
            return true;
        }

        /// Stop the CAMetalDisplayLink so `metalDisplayLink:needsUpdate:` stops firing.
        pub fn stopDisplayLink(self: *Self) callconv(.c) void {
            if (implementation._displayLink.get(self)) |link_ptr| {
                const link: *objc.quartz_core.MetalDisplayLink = @ptrCast(link_ptr);
                link.invalidate();
            }
            implementation._displayLink.set(self, null);
        }
    };
});

/// Queued resize or vsync-mode change, written by the main thread and consumed by render thread
/// in renderThreadFn before each frame.
const PendingSwapChainUpdate = struct {
    width: u32,
    height: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
    pixel_density: f32,
    vsync_mode: Core.VSyncMode,
};

/// Core.windows '.native' field, i.e. per-window platform state.
/// We use a heap-allocated pointer here so that we can pass a stable address through various ObjC
/// classes as context.
pub const Native = *NativeState;

const NativeState = struct {
    core: *Core,
    core_mod: mach.Mod(Core),
    window_id: mach.ObjectID,
    io: std.Io,
    window: *objc.app_kit.Window,
    view: *MACHView,
    metal_descriptor: *gpu.Surface.DescriptorFromMetalLayer,
    ready_sem: objc.system.dispatch_semaphore_t,
    surface: *metal.Surface,

    /// Global event monitor for command-key keyUp workaround. Removed on window teardown.
    key_up_monitor: *objc.objc.Id,

    /// Set by the main thread (windowDidResize / vsync change); consumed by the render thread to
    /// recreate the swap chain before the next frame.
    pending_swap_chain_update: ?PendingSwapChainUpdate = null,

    /// Whether mouse capture is currently active for this window. When true, the OS cursor is
    /// detached from physical mouse motion (via CGAssociateMouseAndMouseCursorPosition(false))
    /// and the application receives `.mouse_motion_relative` events instead of `.mouse_motion`.
    /// Tracks the actual platform state, which can lag the user-requested `Window.mouse_capture`
    /// while focus is lost.
    mouse_captured: bool = false,

    /// Set in enableMouseCapture so we drop the phantom mouse-moved event AppKit synthesizes
    /// in response to CGWarpMouseCursorPosition. Cleared after we drop that first event.
    suppress_next_capture_motion: bool = false,

    /// The cursor's screen position (in CoreGraphics coordinates, top-left origin) recorded
    /// just before we warped to the window center in enableMouseCapture. Used by
    /// disableMouseCapture to restore the cursor to where the user left it, instead of leaving
    /// it stranded at the window center.
    pre_capture_cursor_pos: ?objc.core_graphics.Point = null,

    /// Fallback vsync source used when CAMetalDisplayLink is unavailable (macOS < 14). Unlike
    /// CAMetalDisplayLink it does not vend drawables: it only signals `ready_sem` on every vsync,
    /// and the render thread acquires drawables via nextDrawable() as usual.
    cv_display_link: ?CVDisplayLinkRef = null,

    /// True while `cv_display_link` is running. Gates in-flight CVDisplayLink callbacks that race
    /// with detach.
    use_cv_display_link: bool = false,

    /// Whether rendering for this window is currently paced by a display link (either kind).
    fn hasDisplayLink(n: *NativeState) bool {
        return @atomicLoad(bool, &n.surface.use_display_link, .acquire) or
            @atomicLoad(bool, &n.use_cv_display_link, .acquire);
    }
};

/// Enables mouse capture.
///
/// Safe to call when already captured (no-op).
///
/// Caller must hold `n.core.windows.lock()`.
fn enableMouseCapture(n: *NativeState) void {
    if (n.mouse_captured) return;

    // Disconnect the cursor from physical mouse motion. Done BEFORE warping so the warp
    // doesn't visibly move the cursor, and so the synthesized mouse-moved event produced by
    // CGWarpMouseCursorPosition doesn't reach us with the cursor at an unexpected location.
    // This is the same mechanism SDL3/GLFW use for "relative mouse mode": NSEvent deltas keep
    // arriving while the visible cursor stays put.
    _ = CGAssociateMouseAndMouseCursorPosition(0);

    if (objc.app_kit.Screen.mainScreen()) |screen| {
        const screen_frame = screen.frame();
        const frame = n.window.frame();
        const content_rect = n.window.contentRectForFrameRect(frame);

        // Record the cursor's current screen position (in CoreGraphics top-left coords) so we
        // can restore it in disableMouseCapture. `+[NSEvent mouseLocation]` returns the position
        // in AppKit bottom-left coords; convert using the main display's height.
        const NSPoint = objc.app_kit.Point;
        const cur_appkit = objc.objc.msgSend(objc.app_kit.Event.InternalInfo.class(), "mouseLocation", NSPoint, .{});
        n.pre_capture_cursor_pos = .{
            .x = cur_appkit.x,
            .y = screen_frame.size.height - cur_appkit.y,
        };

        // Warp to window center so a click during capture isn't interpreted by AppKit as a
        // title bar / window edge drag/resize gesture.
        //
        // CGWarpMouseCursorPosition uses CoreGraphics screen coordinates (top-left origin), but
        // NSWindow.frame is in AppKit screen coordinates (bottom-left origin); convert.
        const center_x = content_rect.origin.x + content_rect.size.width / 2.0;
        const center_y_appkit = content_rect.origin.y + content_rect.size.height / 2.0;
        const center_y_cg = screen_frame.size.height - center_y_appkit;
        _ = CGWarpMouseCursorPosition(.{ .x = center_x, .y = center_y_cg });
    }

    objc.app_kit.Cursor.hide();

    n.mouse_captured = true;
    // Drop the first motion event we receive: CGWarpMouseCursorPosition produces a synthesized
    // mouse-moved event whose delta reflects the warp distance, not real mouse motion. We don't
    // want to report that phantom delta to the application.
    n.suppress_next_capture_motion = true;
    n.core.pushEvent(.{ .mouse_capture_gained = .{ .window_id = n.window_id } });
}

/// Release mouse capture or deny a pending request.
///
/// Safe to call when no capture is active and `denied = false` (no-op).
///
/// Caller must hold `n.core.windows.lock()`.
fn disableMouseCapture(n: *NativeState, denied: bool) void {
    if (!n.mouse_captured) {
        // We want to disable mouse capture, but its already not active.
        if (!denied) return; // It wasn't denied, so nothing to do.

        // Mouse capture was denied
        n.core.windows.setRaw(n.window_id, .mouse_capture, false);
        n.core.pushEvent(.{ .mouse_capture_lost = .{ .window_id = n.window_id, .denied = true } });
        return;
    }

    // Mouse is captured, so uncapture. Restore the cursor to where it was before capture
    // (warp while still disassociated, so the cursor's logical position is updated without a
    // visible jump, then re-associate so subsequent physical motion is picked up from there).
    if (n.pre_capture_cursor_pos) |pos| _ = CGWarpMouseCursorPosition(pos);
    n.pre_capture_cursor_pos = null;
    _ = CGAssociateMouseAndMouseCursorPosition(1);

    // Respect the user's separate cursor_visible preference; only unhide if the application
    // wants the cursor visible.
    if (n.core.windows.get(n.window_id, .cursor_visible)) objc.app_kit.Cursor.unhide();

    n.mouse_captured = false;
    n.suppress_next_capture_motion = false;
    n.core.windows.setRaw(n.window_id, .mouse_capture, false);
    n.core.pushEvent(.{ .mouse_capture_lost = .{ .window_id = n.window_id, .denied = denied } });
}

var global_render_loop: ?*RenderLoop = null;
var did_set_app_activation_policy: bool = false;

/// Shared render loop for all windows. The render thread waits for the app thread's snapshot
/// (frame_ready), then waits for vsync via one window's display link semaphore, applies pending
/// swap chain updates, and calls Core.renderFrame to render all windows sequentially.
const RenderLoop = struct {
    core: *Core = undefined,
    core_mod: mach.Mod(Core) = undefined,
    io: std.Io = undefined,
    running: std.atomic.Value(bool) = .init(true),
    thread: std.Thread = undefined,

    /// Spawns the render thread.
    fn start(self: *RenderLoop) error{ThreadSpawnFailed}!void {
        self.thread = std.Thread.spawn(.{}, renderThreadFn, .{self}) catch return error.ThreadSpawnFailed;
    }

    /// Starts the CAMetalDisplayLink for a window. Called during window creation and when
    /// vsync is re-enabled at runtime.
    fn attachDisplayLink(n: *NativeState) void {
        // Tell SwapChain.getCurrentTextureView (on the render thread) to consume display link
        // drawables instead of calling nextDrawable. This MUST be set before startDisplayLink,
        // because once the display link is started, Metal forbids nextDrawable() calls and the
        // render thread could race in between.
        @atomicStore(bool, &n.surface.use_display_link, true, .release);

        // The display link provides external vsync pacing, so disable the layer's own
        // displaySyncEnabled to prevent present() from blocking a second time.
        n.surface.layer.setDisplaySyncEnabled(false);

        // Start the display link.
        if (!n.view.call(.startDisplayLink, .{})) {
            // CAMetalDisplayLink requires macOS 14+. Fall back to a CVDisplayLink that only paces
            // the render thread, with drawables acquired via nextDrawable() and the layer's own
            // displaySyncEnabled preventing tearing.
            @atomicStore(bool, &n.surface.use_display_link, false, .release);
            n.surface.layer.setDisplaySyncEnabled(true);
            if (!startCVDisplayLink(n)) {
                log.err("no display link available, rendering without vsync pacing", .{});
            }
            return;
        }
    }

    /// Starts a CVDisplayLink that signals `ready_sem` on every vsync. Returns false if one could
    /// not be created.
    fn startCVDisplayLink(n: *NativeState) bool {
        if (n.cv_display_link == null) {
            var link: ?CVDisplayLinkRef = null;
            if (CVDisplayLinkCreateWithActiveCGDisplays(&link) != kCVReturnSuccess) return false;
            _ = CVDisplayLinkSetOutputCallback(link.?, &cvDisplayLinkCallback, n);
            n.cv_display_link = link;
        }
        @atomicStore(bool, &n.use_cv_display_link, true, .release);
        if (CVDisplayLinkStart(n.cv_display_link.?) != kCVReturnSuccess) {
            @atomicStore(bool, &n.use_cv_display_link, false, .release);
            return false;
        }
        return true;
    }

    /// Stops and releases the fallback CVDisplayLink, if any. CVDisplayLinkStop blocks until any
    /// in-flight callback has returned, so `n` is safe to free afterwards.
    fn stopCVDisplayLink(n: *NativeState) void {
        @atomicStore(bool, &n.use_cv_display_link, false, .release);
        const link = n.cv_display_link orelse return;
        _ = CVDisplayLinkStop(link);
        CVDisplayLinkRelease(link);
        n.cv_display_link = null;
    }

    /// Stops the CAMetalDisplayLink for a window's view. Called when vsync is disabled or when a
    /// window is being destroyed.
    fn detachDisplayLink(n: *NativeState) void {
        // Stop the display link.
        n.view.call(.stopDisplayLink, .{});
        stopCVDisplayLink(n);

        // Tell SwapChain.getCurrentTextureView to use nextDrawable again, and gate
        // `metalDisplayLink:needsUpdate:` from forwarding any in-flight vsync notification.
        @atomicStore(bool, &n.surface.use_display_link, false, .release);

        // Release any unconsumed drawable left by displayLinkWake.
        const pending_ptr: *usize = @ptrCast(&n.surface.pending_drawable);
        const prev = @atomicRmw(usize, pending_ptr, .Xchg, 0, .acq_rel);
        if (prev != 0) {
            const prev_ptr: *objc.quartz_core.MetalDrawable = @ptrFromInt(prev);
            prev_ptr.release();
        }
    }

    /// Stops the render loop, tears down all display links, and joins the render thread. Called
    /// during app exit.
    fn stop(self: *RenderLoop) void {
        // Signal the render thread to exit.
        self.running.store(false, .release);

        // The render thread may be blocked on dispatch_semaphore_wait for a vsync signal. Stop each
        // window's display link and signal its semaphore to unblock the render thread.
        {
            self.core.windows.lockShared();
            defer self.core.windows.unlockShared();
            var windows = self.core.windows.slice();
            while (windows.next()) |window_id| {
                if (self.core.windows.get(window_id, .native)) |n| {
                    n.view.call(.stopDisplayLink, .{});
                    stopCVDisplayLink(n);
                    _ = objc.system.dispatch_semaphore_signal(n.ready_sem);
                }
            }
        }

        // The render thread may also be blocked on frame_ready (waiting for the app thread's
        // snapshot), so wake it / allow it to observe running=false.
        self.core.frame_ready.set(self.io);

        // Wait for render thread to exit.
        self.thread.join();
    }

    /// Render thread entry point.
    fn renderThreadFn(self: *RenderLoop) void {
        while (self.running.load(.acquire)) {
            // Wait for the app to signal snapshotEnd() and indicate a frame is ready for drawing.
            self.core.frame_ready.waitUncancelable(self.io);
            self.core.frame_ready.reset();

            // If we want to stop the render loop, exit now.
            if (!self.running.load(.acquire)) break;

            // vsync: if ALL windows have an active display link, wait for one to signal vsync. If
            // ANY window lacks a display link (vsync off, or not yet attached), skip the wait: that
            // window needs uncapped rendering, and display-link windows will naturally skip frames
            // when no drawable is available (getCurrentTextureView returns null). We check
            // hasDisplayLink (the actual hardware state) rather than vsync_mode (the desired
            // state that the main thread hasn't applied yet).
            {
                var all_have_display_link = true;
                var wait_n: ?*NativeState = null;
                {
                    self.core.windows.lockShared();
                    defer self.core.windows.unlockShared();

                    var windows = self.core.windows.slice();
                    while (windows.next()) |window_id| {
                        const n = self.core.windows.get(window_id, .native) orelse continue;
                        if (!n.hasDisplayLink()) {
                            all_have_display_link = false;
                            break;
                        }
                        if (wait_n == null) wait_n = n;
                    }
                }

                if (all_have_display_link) {
                    if (wait_n) |n| {
                        _ = objc.system.dispatch_semaphore_wait(
                            n.ready_sem,
                            objc.system.DISPATCH_TIME_FOREVER,
                        );
                    }
                }
            }

            // Now that we waited for vsync, check if we should exit again before rendering the
            // frame.
            if (!self.running.load(.acquire)) break;

            // Apply any pending swap chain updates (resizes, vsync changes) before rendering.
            {
                self.core.windows.lock();
                defer self.core.windows.unlock();
                var windows = self.core.windows.slice();
                while (windows.next()) |window_id| {
                    var core_window = self.core.windows.getValue(window_id);
                    const n = core_window.native orelse continue;
                    const update = n.pending_swap_chain_update orelse continue;

                    n.pending_swap_chain_update = null;
                    core_window.width = update.width;
                    core_window.height = update.height;
                    core_window.framebuffer_width = update.framebuffer_width;
                    core_window.framebuffer_height = update.framebuffer_height;
                    core_window.pixel_density = update.pixel_density;
                    core_window.swap_chain_descriptor.width = update.framebuffer_width;
                    core_window.swap_chain_descriptor.height = update.framebuffer_height;
                    core_window.swap_chain_descriptor.present_mode = switch (update.vsync_mode) {
                        .none_low_latency, .none_max_throughput => .immediate,
                        .double, .adaptive, .low_latency => .fifo,
                        .triple => .fifo,
                    };
                    core_window.swap_chain_descriptor.max_buffered_frames = switch (update.vsync_mode) {
                        .double, .adaptive, .low_latency => 2,
                        .triple, .none_low_latency, .none_max_throughput => 3,
                    };
                    core_window.swap_chain.release();
                    core_window.swap_chain = core_window.device.createSwapChain(
                        core_window.surface,
                        &core_window.swap_chain_descriptor,
                    );
                    self.core.windows.setValueRaw(window_id, core_window);
                }
            }

            // Render a frame on all windows.
            self.core.renderFrame(self.core_mod, self.io) catch {
                self.core.oom.store(true, .release);
            };
        }
    }
};

// CAMetalDisplayLink callback, invoked on every vsync for the window via MACHView's
// `metalDisplayLink:needsUpdate:` IMP.
fn displayLinkWake(n: *NativeState, drawable: *objc.quartz_core.MetalDrawable) void {
    // Retain the drawable so it survives beyond this callback. It will be released in either
    // SwapChain.getCurrentTextureView or SwapChain.deinit
    _ = drawable.retain();

    // When the render thread is slower than the display refresh rate, the display link still
    // fires every vsync, so if the render thread hasn't consumed the previous drawable yet we
    // should release the old one and replace it with the new one.
    const pending_ptr: *usize = @ptrCast(&n.surface.pending_drawable);
    const prev = @atomicRmw(usize, pending_ptr, .Xchg, @intFromPtr(drawable), .acq_rel);
    if (prev != 0) {
        const prev_ptr: *objc.quartz_core.MetalDrawable = @ptrFromInt(prev);
        prev_ptr.release();
    }

    // Signal to the render thread that a vsync has occurred.
    _ = objc.system.dispatch_semaphore_signal(n.ready_sem);
}

// CVDisplayLink callback, invoked on a CoreVideo thread every vsync. Only used as a fallback
// when CAMetalDisplayLink is unavailable (macOS < 14).
fn cvDisplayLinkCallback(
    _: CVDisplayLinkRef,
    _: *const anyopaque, // in_now: *const CVTimeStamp
    _: *const anyopaque, // in_output_time: *const CVTimeStamp
    _: u64, // flags_in: CVOptionFlags
    _: *u64, // flags_out: *CVOptionFlags
    ctx: ?*anyopaque,
) callconv(.c) i32 {
    const n: *NativeState = @ptrCast(@alignCast(ctx.?));
    if (!@atomicLoad(bool, &n.use_cv_display_link, .acquire)) return kCVReturnSuccess;

    // Signal to the render thread that a vsync has occurred.
    _ = objc.system.dispatch_semaphore_signal(n.ready_sem);
    return kCVReturnSuccess;
}

const CVDisplayLinkRef = *opaque {};
const CVDisplayLinkOutputCallback = *const fn (CVDisplayLinkRef, *const anyopaque, *const anyopaque, u64, *u64, ?*anyopaque) callconv(.c) i32;
const kCVReturnSuccess: i32 = 0;
extern "CoreVideo" fn CVDisplayLinkCreateWithActiveCGDisplays(link_out: *?CVDisplayLinkRef) i32;
extern "CoreVideo" fn CVDisplayLinkSetOutputCallback(link: CVDisplayLinkRef, callback: CVDisplayLinkOutputCallback, user_info: ?*anyopaque) i32;
extern "CoreVideo" fn CVDisplayLinkStart(link: CVDisplayLinkRef) i32;
extern "CoreVideo" fn CVDisplayLinkStop(link: CVDisplayLinkRef) i32;
extern "CoreVideo" fn CVDisplayLinkRelease(link: CVDisplayLinkRef) void;

// TODO(core): port libdispatch and use it instead of doing this directly.
extern "System" fn dispatch_async_f(queue: *anyopaque, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "System" var _dispatch_main_q: anyopaque;

extern "CoreGraphics" fn CGAssociateMouseAndMouseCursorPosition(connected: c_int) c_int;
extern "CoreGraphics" fn CGWarpMouseCursorPosition(point: objc.core_graphics.Point) c_int;

// Context pointer + C function pointer that drive each main-thread tick. Both set by `run()`
// before NSApp.run() starts. `applicationDidFinishLaunching:` runs the first tick directly,
// subsequent ticks come from `wakeMainThread` via `dispatch_async_f`.
var main_tick_ctx: ?*anyopaque = null;
var main_tick_fn: ?*const fn (?*anyopaque) callconv(.c) void = null;

// When true, a main tick is already enqueued on the main dispatch queue and additional wakes are
// deduplicated. Required because `dispatch_async_f` (unlike e.g. `std.Io.Event.set`) does NOT
// coalesce, so without this flag every wake would enqueue another tick with no upper bound on
// backlog.
var main_tick_pending: std.atomic.Value(bool) = .init(false);

// Called by Core when the user calls Core.snapshotStart, Core.events, core.exit
pub fn wakeMainThread(_: *Core) void {
    if (main_tick_pending.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
        const f = main_tick_fn orelse return;
        dispatch_async_f(&_dispatch_main_q, main_tick_ctx, f);
    }
}

/// Application entry point called by Core.main. Sets up the NSApplication delegate and run loop.
/// The main thread does NOT busy-loop: each tick runs once per call to `wakeMainThread`, which
/// is invoked by the app thread from `events()` and `snapshotStart()`.
pub fn run(comptime on_each_update_fn: anytype, args_tuple: std.meta.ArgsTuple(@TypeOf(on_each_update_fn))) noreturn {
    const Args = @TypeOf(args_tuple);
    // run() is noreturn, so this local stays valid for the lifetime of the process. Its
    // address is what we pass to dispatch_async_f as the context.
    var args = args_tuple;
    const Helper = struct {
        pub fn tick(ctx: ?*anyopaque) callconv(.c) void {
            const a: *Args = @ptrCast(@alignCast(ctx.?));

            // Reset the wake flag BEFORE running tick so any wake that arrives during tick
            // re-arms a follow-up dispatch.
            main_tick_pending.store(false, .release);

            if (@call(.auto, on_each_update_fn, a.*) catch false) {
                // Do not auto-redispatch. The next tick happens only when `wakeMainThread`
                // is called (e.g. from the app thread's `events()` / `snapshotStart()`).
            } else {
                // NSApp.run() never returns, so exit the process here.
                std.process.exit(0);
            }
        }
    };
    main_tick_ctx = &args;
    main_tick_fn = &Helper.tick;

    // `NSApplicationMain()` and `UIApplicationMain()` never return, so there's no point in trying to add any kind of cleanup work here.
    const ns_app = objc.app_kit.Application.sharedApplication();

    const delegate = MACHAppDelegate.allocInit();
    ns_app.setDelegate(@ptrCast(delegate));

    ns_app.run();
    unreachable;
}

/// Called by Core.tick on the main thread each application tick. Creates new windows, applies
/// changes (window title, size, vsync, etc.), and handles pending window destruction.
pub fn tick(core: *Core, core_mod: mach.Mod(Core), io: std.Io) !void {
    core.windows.lock();
    var unlocked = false;
    defer if (!unlocked) core.windows.unlock();

    // Tear down native resources for deleted windows on the main thread where AppKit calls are safe.
    var deleted_windows = core.windows.sliceDeleted();
    while (deleted_windows.next()) |window_id| {
        const n = core.windows.get(window_id, .native) orelse continue;
        objc.app_kit.Event.removeMonitor(n.key_up_monitor);
        if (n.hasDisplayLink()) {
            RenderLoop.detachDisplayLink(n);
        }
        // Signal the sem so the render thread (if blocked waiting on it) can unblock.
        _ = objc.system.dispatch_semaphore_signal(n.ready_sem);
        n.window.setIsVisible(false);
        n.view.release();
        n.window.release();
        core.allocator.destroy(n.metal_descriptor);
        core.allocator.destroy(n);
        core.windows.setRaw(window_id, .native, null);
        // The window_id object itself will be freed inside snapshotStart()
    }

    var windows = core.windows.slice();
    while (windows.next()) |window_id| {
        const core_window = core.windows.getValue(window_id);

        const n = core_window.native orelse {
            if (core_window.on_render != null) try initWindow(core, core_mod, window_id, io);
            continue;
        };

        // Update window decoration color.
        const native_window: *objc.app_kit.Window = n.window;
        if (core.windows.updated(window_id, .decoration_color)) {
            if (core_window.decoration_color) |decoration_color| {
                const color = objc.app_kit.Color.colorWithRed_green_blue_alpha(
                    decoration_color.r,
                    decoration_color.g,
                    decoration_color.b,
                    decoration_color.a,
                );
                native_window.setBackgroundColor(color);
                native_window.setTitlebarAppearsTransparent(true);
            } else {
                native_window.setTitlebarAppearsTransparent(false);
            }
        }

        // Update window title.
        if (core.windows.updated(window_id, .title)) {
            const string = objc.foundation.String.allocInit();
            defer string.release();
            n.window.setTitle(string.initWithUTF8String(core_window.title));
        }

        // Update window width/height.
        if (core.windows.updated(window_id, .width) or core.windows.updated(window_id, .height)) {
            var frame = native_window.frame();
            frame.size.width = @floatFromInt(core.windows.get(window_id, .width));
            frame.size.height = @floatFromInt(core.windows.get(window_id, .height));
            native_window.setFrame_display_animate(
                native_window.frameRectForContentRect(frame),
                true,
                true,
            );
        }

        // Update cursor visibility. If the cursor is captured we keep it hidden regardless;
        // capture takes priority over the app's cursor_visible preference.
        if (core.windows.updated(window_id, .cursor_visible)) {
            if (core_window.cursor_visible) {
                if (!n.mouse_captured) objc.app_kit.Cursor.unhide();
            } else {
                objc.app_kit.Cursor.hide();
            }
        }

        // Update window mouse capture state to match the user's request. macOS won't deliver
        // mouse events to an unfocused window, so requesting capture without focus is denied
        // (the user must focus the window first, then request again).
        if (core.windows.updated(window_id, .mouse_capture)) {
            if (core_window.mouse_capture) {
                const is_key = objc.objc.msgSend(n.window, "isKeyWindow", bool, .{});
                if (is_key) {
                    enableMouseCapture(n);
                } else {
                    // Window isn't focused; capture is unavailable right now (not actively
                    // denied), so we just immediately lose it. The user can re-request once
                    // the window is focused.
                    disableMouseCapture(n, false);
                }
            } else {
                disableMouseCapture(n, false);
            }
        }

        // Update window cursor shape.
        if (core.windows.updated(window_id, .cursor_shape)) {
            const Cursor = objc.app_kit.Cursor;

            // Pop the current cursor, then push the new one so AppKit's
            // cursor stack reflects the updated shape.
            Cursor.T_pop();
            switch (core_window.cursor_shape) {
                .arrow => Cursor.arrowCursor().push(),
                .ibeam => Cursor.IBeamCursor().push(),
                .crosshair => Cursor.crosshairCursor().push(),
                .pointing_hand => Cursor.pointingHandCursor().push(),
                .not_allowed => Cursor.operationNotAllowedCursor().push(),
                .resize_ns => Cursor.resizeUpDownCursor().push(),
                .resize_ew => Cursor.resizeLeftRightCursor().push(),
                .resize_all => Cursor.closedHandCursor().push(),
                else => std.log.warn("Unsupported cursor", .{}),
            }
        }

        // Update window vsync.
        if (core.windows.updated(window_id, .vsync_mode)) {
            try ensureRenderLoop(core, core_mod, io);
            const want_vsync = !core_window.vsync_mode.isNone();

            // Only detach/attach the display link when transitioning between vsync-on and
            // vsync-off. Switching between vsync-on modes (e.g. .double → .triple) only
            // needs a swap chain recreation — the display link is already running.
            const have_display_link = n.hasDisplayLink();
            if (want_vsync and !have_display_link) {
                RenderLoop.attachDisplayLink(n);
            } else if (!want_vsync and have_display_link) {
                RenderLoop.detachDisplayLink(n);
            }

            // Queue a swap chain recreation for the render thread.
            n.pending_swap_chain_update = .{
                .width = core_window.width,
                .height = core_window.height,
                .framebuffer_width = core_window.framebuffer_width,
                .framebuffer_height = core_window.framebuffer_height,
                .pixel_density = core_window.pixel_density,
                .vsync_mode = core_window.vsync_mode,
            };

            // Wake the render thread so it picks up the swap chain update promptly.
            _ = objc.system.dispatch_semaphore_signal(n.ready_sem);
        }
    }

    // Release the windows lock before stopping the render loop: rl.stop() acquires it itself.
    core.windows.unlock();
    unlocked = true;

    // Consider mach.Core exiting/exited state.
    const state = core.state.load(.acquire);
    if (state == .exiting or state == .exited) {
        // Stop the render loop before GPU resources are released.
        if (global_render_loop) |rl| {
            rl.stop();
            core.allocator.destroy(rl);
            global_render_loop = null;
        }
    } else if (global_render_loop == null) {
        // Ensure a render loop is always running (with or without display link).
        try ensureRenderLoop(core, core_mod, io);
    }
}

/// Creates the native AppKit window, Metal layer, view, and display link for a new mach.Core window
/// Called from tick() when a window has on_render set but no native state yet.
fn initWindow(
    core: *Core,
    core_mod: mach.Mod(Core),
    window_id: mach.ObjectID,
    io: std.Io,
) !void {
    var core_window = core.windows.getValue(window_id);

    // Allocate the heap-stable NativeState up front. ObjC ivars and the keyUpMonitor block
    // capture this pointer; ObjC/Metal fields are populated as they're created below.
    const n = try core.allocator.create(NativeState);
    n.* = .{
        .core = core,
        .core_mod = core_mod,
        .window_id = window_id,
        .io = io,
        .ready_sem = objc.system.dispatch_semaphore_create(0) orelse
            return error.SemaphoreCreateFailed,

        // Initialized later in this function
        .window = undefined,
        .view = undefined,
        .metal_descriptor = undefined,
        .surface = undefined,
        .key_up_monitor = undefined,
    };

    // Make the process a foreground UI application on the first window creation.
    if (!did_set_app_activation_policy) {
        did_set_app_activation_policy = true;
        _ = objc.app_kit.Application.sharedApplication().setActivationPolicy(
            objc.app_kit.ApplicationActivationPolicyRegular,
        );
    }

    {
        // On macos, the command key in particular seems to be handled a bit differently and tends
        // to block the `keyUp` event from firing. To remedy this, we borrow the same fix GLFW uses
        // and add a monitor.
        const commandFn = struct {
            pub fn commandFn(block: *objc.foundation.BlockLiteral(*NativeState), event: *objc.app_kit.Event) callconv(.c) ?*objc.app_kit.Event {
                const ns = block.context;

                // Skip if the window isn't fully registered yet (initWindow still in progress).
                ns.core.windows.lockShared();
                const registered = ns.core.windows.get(ns.window_id, .native) != null;
                ns.core.windows.unlockShared();

                if (registered and event.modifierFlags() & objc.app_kit.EventModifierFlagCommand != 0) {
                    ns.window.sendEvent(event);
                }
                return event;
            }
        }.commandFn;

        var commandBlock = objc.foundation.stackBlockLiteral(commandFn, n, null, null);
        n.key_up_monitor = objc.app_kit.Event.addLocalMonitorForEventsMatchingMask_handler(
            objc.app_kit.EventMaskKeyUp,
            commandBlock.asBlock().copy(),
        ).?;
    }

    // Create the Metal layer.
    n.metal_descriptor = try core.allocator.create(gpu.Surface.DescriptorFromMetalLayer);
    const layer = objc.quartz_core.MetalLayer.new();
    defer layer.release();
    n.metal_descriptor.* = .{ .layer = layer };
    core_window.surface_descriptor = .{};
    core_window.surface_descriptor.next_in_chain = .{ .from_metal_layer = n.metal_descriptor };

    // Handle window transparency
    if (core_window.transparent) layer.as(objc.quartz_core.Layer).setOpaque(false);

    // Handle window styling
    const screen = objc.app_kit.Screen.mainScreen();
    const rect = objc.core_graphics.Rect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(core_window.width), .height = @floatFromInt(core_window.height) },
    };
    const window_style =
        (if (core_window.display_mode == .fullscreen) objc.app_kit.WindowStyleMaskFullScreen else 0) |
        (if (core_window.decorated) objc.app_kit.WindowStyleMaskTitled else 0) |
        (if (core_window.decorated) objc.app_kit.WindowStyleMaskClosable else 0) |
        (if (core_window.decorated) objc.app_kit.WindowStyleMaskMiniaturizable else 0) |
        (if (core_window.decorated) objc.app_kit.WindowStyleMaskResizable else 0) |
        (if (!core_window.decorated) objc.app_kit.WindowStyleMaskFullSizeContentView else 0);

    // Create the AppKit window.
    n.window = objc.app_kit.Window.alloc().initWithContentRect_styleMask_backing_defer_screen(
        rect,
        window_style,
        objc.app_kit.BackingStoreBuffered,
        false,
        screen,
    );
    n.window.setReleasedWhenClosed(false);

    const pixel_density: f32 = @floatCast(n.window.backingScaleFactor());
    const window_width: f32 = @floatFromInt(core_window.width);
    const window_height: f32 = @floatFromInt(core_window.height);

    core_window.framebuffer_width = @intFromFloat(window_width * pixel_density);
    core_window.framebuffer_height = @intFromFloat(window_height * pixel_density);
    core_window.pixel_density = pixel_density;
    // macOS has no clean per-window "user wants bigger UI" API equivalent to Windows'
    // GetDpiForWindow, so display_scale stays at 1.0.
    //
    // Caveat: macOS's "System Settings -> Displays -> Larger Text" picker does not surface to apps
    // as a pixel_density change OR a per-window scale factor. All those modes report the same
    // backingScaleFactor (2.0 on Retina); the only thing that changes is the screen's reported
    // point dimensions. The OS then transparently stretches the same framebuffer to a larger
    // on-screen physical size when the user picks "Larger Text". So an 800x600 window has identical
    // pixel_density / framebuffer_width / framebuffer_height irrespective of which preference is
    // chosen there.
    //
    // The "Accessibility -> Display -> Text Size" slider is also not exposed as a scale factor,
    // instead that is on applications to respect using NSFont preferred-font-size APIs.
    core_window.display_scale = 1.0;

    // initWithFrame is overridden in our MACHView, which creates a tracking area for mouse
    // tracking
    n.view = MACHView.alloc().call(.initWithFrame, .{rect}).?;
    n.view.as(objc.app_kit.View).setLayer(@ptrCast(layer));
    MACHView.implementation._state.set(n.view, n);
    n.window.setContentView(@ptrCast(n.view));

    // Center the window
    n.window.center();

    // Set decoration colors
    if (core_window.decoration_color) |decoration_color| {
        const color = objc.app_kit.Color.colorWithRed_green_blue_alpha(
            decoration_color.r,
            decoration_color.g,
            decoration_color.b,
            decoration_color.a,
        );
        n.window.setBackgroundColor(color);
        n.window.setTitlebarAppearsTransparent(true);
    } else {
        // Default to black so the window doesn't flash gray before the first frame.
        n.window.setBackgroundColor(objc.app_kit.Color.colorWithRed_green_blue_alpha(0, 0, 0, 1));
    }

    // Set window title
    const string = objc.foundation.String.allocInit();
    defer string.release();
    n.window.setTitle(string.initWithUTF8String(core_window.title));

    // NSWindowDelegate receives resize and close notifications from AppKit.
    const delegate = MACHWindowDelegate.allocInit();
    MACHWindowDelegate.implementation._state.set(delegate, n);
    defer n.window.setDelegate(@ptrCast(delegate));

    // Store .native on the mach.Core window object.
    core_window.native = n;
    core.windows.setValueRaw(window_id, core_window);

    // Shared mach.Core.initWindow logic across windowing backends.
    try core.initWindow(window_id);

    // Start or update the global render loop if needed
    try ensureRenderLoop(core, core_mod, core.windows.internal.io);

    // Now that core.initWindow has created the surface, wire it into NativeState and attach the
    // CAMetalDisplayLink so vsync pacing begins immediately.
    core_window = core.windows.getValue(window_id);
    n.surface = @ptrCast(@alignCast(core_window.surface));
    RenderLoop.attachDisplayLink(n);

    // Show the window only after the surface and display link are ready, so the user never sees
    // the window without rendered content on it.
    n.window.setIsVisible(true);
    n.window.makeKeyAndOrderFront(null);
}

/// Ensures the global render loop is running. Creates one if it doesn't exist yet. The render loop
/// is destroyed in tick() when the app exits.
fn ensureRenderLoop(core: *Core, core_mod: mach.Mod(Core), io: std.Io) !void {
    if (global_render_loop != null) return;

    const rl = try core.allocator.create(RenderLoop);
    rl.* = .{ .core = core, .core_mod = core_mod, .io = io };
    try rl.start();
    global_render_loop = rl;
}

fn machPhaseFromPhase(phase: objc.app_kit.EventPhase) Core.GesturePhase {
    return switch (phase) {
        objc.app_kit.EventPhaseNone => .none,
        objc.app_kit.EventPhaseMayBegin => .may_begin,
        objc.app_kit.EventPhaseBegan => .began,
        objc.app_kit.EventPhaseChanged => .changed,
        objc.app_kit.EventPhaseStationary => .stationary,
        objc.app_kit.EventPhaseEnded => .ended,
        objc.app_kit.EventPhaseCancelled => .cancelled,
        else => .none,
    };
}

fn machModifierFromModifierFlag(modifier_flag: usize) KeyMods {
    var modifier: KeyMods = .{
        .alt = false,
        .caps_lock = false,
        .control = false,
        .num_lock = false,
        .shift = false,
        .super = false,
        .help = false,
        .function = false,
    };

    if (modifier_flag & objc.app_kit.EventModifierFlagOption != 0)
        modifier.alt = true;

    if (modifier_flag & objc.app_kit.EventModifierFlagCapsLock != 0)
        modifier.caps_lock = true;

    if (modifier_flag & objc.app_kit.EventModifierFlagControl != 0)
        modifier.control = true;

    if (modifier_flag & objc.app_kit.EventModifierFlagShift != 0)
        modifier.shift = true;

    if (modifier_flag & objc.app_kit.EventModifierFlagCommand != 0)
        modifier.super = true;

    if (modifier_flag & objc.app_kit.EventModifierFlagNumericPad != 0)
        modifier.num_lock = true;

    if (modifier_flag & objc.app_kit.EventModifierFlagHelp != 0)
        modifier.help = true;

    if (modifier_flag & objc.app_kit.EventModifierFlagFunction != 0)
        modifier.function = true;

    return modifier;
}

fn machKeyFromKeycode(keycode: c_ushort) Key {
    comptime var table: [256]Key = undefined;
    comptime for (&table, 1..) |*ptr, i| {
        ptr.* = switch (i) {
            0x35 => .escape,
            0x12 => .one,
            0x13 => .two,
            0x14 => .three,
            0x15 => .four,
            0x17 => .five,
            0x16 => .six,
            0x1A => .seven,
            0x1C => .eight,
            0x19 => .nine,
            0x1D => .zero,
            0x1B => .minus,
            0x18 => .equal,
            0x33 => .backspace,
            0x30 => .tab,
            0x0C => .q,
            0x0D => .w,
            0x0E => .e,
            0x0F => .r,
            0x11 => .t,
            0x10 => .y,
            0x20 => .u,
            0x22 => .i,
            0x1F => .o,
            0x23 => .p,
            0x21 => .left_bracket,
            0x1E => .right_bracket,
            0x24 => .enter,
            0x3B => .left_control,
            0x00 => .a,
            0x01 => .s,
            0x02 => .d,
            0x03 => .f,
            0x05 => .g,
            0x04 => .h,
            0x26 => .j,
            0x28 => .k,
            0x25 => .l,
            0x29 => .semicolon,
            0x27 => .apostrophe,
            0x32 => .grave,
            0x38 => .left_shift,
            //0x2A => .backslash, // Iso backslash instead?
            0x06 => .z,
            0x07 => .x,
            0x08 => .c,
            0x09 => .v,
            0x0B => .b,
            0x2D => .n,
            0x2E => .m,
            0x2B => .comma,
            0x2F => .period,
            0x2C => .slash,
            0x3C => .right_shift,
            0x43 => .kp_multiply,
            0x3A => .left_alt,
            0x31 => .space,
            0x39 => .caps_lock,
            0x7A => .f1,
            0x78 => .f2,
            0x63 => .f3,
            0x76 => .f4,
            0x60 => .f5,
            0x61 => .f6,
            0x62 => .f7,
            0x64 => .f8,
            0x65 => .f9,
            0x6D => .f10,
            0x59 => .kp_7,
            0x5B => .kp_8,
            0x5C => .kp_9,
            0x4E => .kp_subtract,
            0x56 => .kp_4,
            0x57 => .kp_5,
            0x58 => .kp_6,
            0x45 => .kp_add,
            0x53 => .kp_1,
            0x54 => .kp_2,
            0x55 => .kp_3,
            0x52 => .kp_0,
            0x41 => .kp_decimal,
            0x69 => .print,
            0x2A => .iso_backslash,
            0x67 => .f11,
            0x6F => .f12,
            0x51 => .kp_equal,
            //0x64 => .f13, GLFW doesnt have a f13?
            0x6B => .f14,
            0x71 => .f15,
            0x6A => .f16,
            0x40 => .f17,
            0x4F => .f18,
            0x50 => .f19,
            0x5A => .f20,
            0x4C => .kp_enter,
            0x3E => .right_control,
            0x4B => .kp_divide,
            0x3D => .right_alt,
            0x47 => .num_lock,
            0x73 => .home,
            0x7E => .up,
            0x74 => .page_up,
            0x7B => .left,
            0x7C => .right,
            0x77 => .end,
            0x7D => .down,
            0x79 => .page_down,
            0x72 => .insert,
            0x75 => .delete,
            0x37 => .left_super,
            0x36 => .right_super,
            0x6E => .menu,
            else => .unknown,
        };
    };
    return if (keycode > 0 and keycode <= table.len) table[keycode - 1] else if (keycode == 0) .a else .unknown;
}
