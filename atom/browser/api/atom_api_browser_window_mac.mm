// Copyright (c) 2018 GitHub, Inc.
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file.

#include "atom/browser/api/atom_api_browser_window.h"

#import <Cocoa/Cocoa.h>

#include "atom/browser/native_browser_view.h"
#include "atom/common/draggable_region.h"
#include "base/mac/scoped_nsobject.h"

@interface NSView (WebContentsView)
- (void)setMouseDownCanMoveWindow:(BOOL)can_move;
@end

@interface ControlRegionView : NSView
@end

@implementation ControlRegionView

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (NSView*)hitTest:(NSPoint)aPoint {
  return nil;
}

@end

namespace atom {

namespace api {

namespace {

// Return a vector of non-draggable regions that fill a window of size
// |width| by |height|, but leave gaps where the window should be draggable.
std::vector<gfx::Rect> CalculateNonDraggableRegions(
    std::unique_ptr<SkRegion> draggable,
    int width,
    int height) {
  std::vector<gfx::Rect> result;
  std::unique_ptr<SkRegion> non_draggable(new SkRegion);
  non_draggable->op(0, 0, width, height, SkRegion::kUnion_Op);
  non_draggable->op(*draggable, SkRegion::kDifference_Op);
  for (SkRegion::Iterator it(*non_draggable); !it.done(); it.next()) {
    result.push_back(gfx::SkIRectToRect(it.rect()));
  }
  return result;
}

}  // namespace

void BrowserWindow::UpdateDraggableRegions(
    content::RenderFrameHost* rfh,
    const std::vector<DraggableRegion>& regions) {
  if (window_->has_frame())
    return;

  // All ControlRegionViews should be added as children of the WebContentsView,
  // because WebContentsView will be removed and re-added when entering and
  // leaving fullscreen mode.
  NSView* webView = web_contents()->GetNativeView();
  NSInteger webViewWidth = NSWidth([webView bounds]);
  NSInteger webViewHeight = NSHeight([webView bounds]);

  if ([webView respondsToSelector:@selector(setMouseDownCanMoveWindow:)]) {
    [webView setMouseDownCanMoveWindow:YES];
  }

  // Remove all ControlRegionViews that are added last time.
  // Note that [webView subviews] returns the view's mutable internal array and
  // it should be copied to avoid mutating the original array while enumerating
  // it.
  base::scoped_nsobject<NSArray> subviews([[webView subviews] copy]);
  for (NSView* subview in subviews.get())
    if ([subview isKindOfClass:[ControlRegionView class]])
      [subview removeFromSuperview];

  // Draggable regions is implemented by having the whole web view draggable
  // (mouseDownCanMoveWindow) and overlaying regions that are not draggable.
  draggable_regions_ = regions;
  std::vector<gfx::Rect> drag_exclude_rects;
  if (regions.empty()) {
    drag_exclude_rects.push_back(gfx::Rect(0, 0, webViewWidth, webViewHeight));
  } else {
    drag_exclude_rects = CalculateNonDraggableRegions(
        DraggableRegionsToSkRegion(regions), webViewWidth, webViewHeight);
  }

  if (window_->browser_view())
    window_->browser_view()->UpdateDraggableRegions(drag_exclude_rects);

  // Create and add a ControlRegionView for each region that needs to be
  // excluded from the dragging.
  for (const auto& rect : drag_exclude_rects) {
    base::scoped_nsobject<NSView> controlRegion(
        [[ControlRegionView alloc] initWithFrame:NSZeroRect]);
    [controlRegion setFrame:NSMakeRect(rect.x(), webViewHeight - rect.bottom(),
                                       rect.width(), rect.height())];
    [webView addSubview:controlRegion];
  }

  // AppKit will not update its cache of mouseDownCanMoveWindow unless something
  // changes. Previously we tried adding an NSView and removing it, but for some
  // reason it required reposting the mouse-down event, and didn't always work.
  // Calling the below seems to be an effective solution.
  [[webView window] setMovableByWindowBackground:NO];
  [[webView window] setMovableByWindowBackground:YES];
}

}  // namespace api

}  // namespace atom
