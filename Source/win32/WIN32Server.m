/* WIN32Server - Implements window handling for MSWindows

   Copyright (C) 2002, 2005 Free Software Foundation, Inc.

   Written by: Fred Kiefer <FredKiefer@gmx.de>
   Date: March 2002
   Part of this code have been re-written by: 
   Tom MacSween <macsweent@sympatico.ca>
   Date August 2005

   This file is part of the GNU Objective C User Interface Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	 See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; see the file COPYING.LIB.
   If not, see <http://www.gnu.org/licenses/> or write to the 
   Free Software Foundation, 51 Franklin Street, Fifth Floor, 
   Boston, MA 02110-1301, USA.
*/

#include "config.h"
#include <Foundation/NSDebug.h>
#include <Foundation/NSString.h>
#include <Foundation/NSArray.h>
#include <Foundation/NSValue.h>
#include <Foundation/NSConnection.h>
#include <Foundation/NSRunLoop.h>
#include <Foundation/NSTimer.h>
#include <Foundation/NSUserDefaults.h>
#include <Foundation/NSException.h>
#include <AppKit/AppKitExceptions.h>
#include <AppKit/NSApplication.h>
#include <AppKit/NSGraphics.h>
#include <AppKit/NSMenu.h>
#include <AppKit/NSWindow.h>
#include <AppKit/NSView.h>
#include <AppKit/NSEvent.h>
#include <AppKit/NSCursor.h>
#include <AppKit/NSText.h>
#include <AppKit/NSTextField.h>
#include <AppKit/DPSOperators.h>
#include <GNUstepGUI/GSTheme.h>

#include "win32/WIN32Server.h"
#include "win32/WIN32Geometry.h"
#ifdef HAVE_WGL
#include "win32/WIN32OpenGL.h"
#endif 

#ifdef __CYGWIN__
#include <sys/file.h>
#endif

#include <math.h>

static BOOL _enableCallbacks = YES;

static NSEvent *process_key_event(WIN32Server *svr, 
                                  HWND hwnd, WPARAM wParam, 
                                  LPARAM lParam, NSEventType eventType);
static NSEvent *process_mouse_event(WIN32Server *svr, 
                                    HWND hwnd, WPARAM wParam, 
                                    LPARAM lParam, NSEventType eventType,
                                    UINT uMsg);

LRESULT CALLBACK MainWndProc(HWND hwnd, UINT uMsg, 
                             WPARAM wParam, LPARAM lParam);

@implementation WIN32Server

- (BOOL) handlesWindowDecorations
{
  return handlesWindowDecorations;
}

- (void) setHandlesWindowDecorations: (BOOL) b
{
  handlesWindowDecorations = b;
}

- (BOOL) usesNativeTaskbar
{
  return usesNativeTaskbar;
}

- (void) setUsesNativeTaskbar: (BOOL) b
{
  usesNativeTaskbar = b;
}

- (void) callback: (id)sender
{
  MSG msg;
  WINBOOL bRet; 
//NSLog(@"Callback");
  while ((bRet = PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) != 0)
    { 
      if (msg.message == WM_QUIT)
        {
          // Exit the program
          return;
        }
      if (bRet == -1)
        {
          // handle the error and possibly exit
        }
      else
        {
          // Don't translate messages, as this would give
          // extra character messages.
          DispatchMessage(&msg); 
        } 
    } 
}

- (BOOL) hasEvent
{
  return (GetQueueStatus(QS_ALLEVENTS) != 0);
}

- (void) receivedEvent: (void*)data
                  type: (RunLoopEventType)type
                 extra: (void*)extra
               forMode: (NSString*)mode
{
#ifdef    __CYGWIN__
  if (type == ET_RDESC)
#else 
  if (type == ET_WINMSG)
#endif
    {
      MSG	*m = (MSG*)extra;

      if (m->message == WM_QUIT)
        {
          [NSApp terminate: nil];
          // Exit the program
          return;
        }
      else
        {
          DispatchMessage(m); 
        } 
    } 
//  if (mode != nil) [self callback: mode];
}


- (NSEvent*) getEventMatchingMask: (unsigned)mask
                       beforeDate: (NSDate*)limit
                           inMode: (NSString*)mode
                          dequeue: (BOOL)flag
{
//  [self callback: nil];
  return [super getEventMatchingMask: mask
                beforeDate: limit
                inMode: mode
                dequeue: flag];
}

- (void) discardEventsMatchingMask: (unsigned)mask
                       beforeEvent: (NSEvent*)limit
{
//  [self callback: nil];
  [super discardEventsMatchingMask: mask
         beforeEvent: limit];
}


// server 

/* Initialize AppKit backend */
+ (void) initializeBackend
{
  NSDebugLog(@"Initializing GNUstep win32 backend.\n");

  [GSDisplayServer setDefaultServerClass: [WIN32Server class]];
}

- (void) _initWin32Context
{
  WNDCLASSEX wc; 
  hinstance = (HINSTANCE)GetModuleHandle(NULL);

  // Register the main window class. 
  wc.cbSize = sizeof(wc);          
  //wc.style = CS_OWNDC; // | CS_HREDRAW | CS_VREDRAW; 
  wc.style = CS_HREDRAW | CS_VREDRAW; 
  wc.lpfnWndProc = (WNDPROC) MainWndProc; 
  wc.cbClsExtra = 0; 
  // Keep extra space for each window, for OFF_LEVEL and OFF_ORDERED
  wc.cbWndExtra = WIN_EXTRABYTES; 
  wc.hInstance = hinstance; 
  wc.hIcon = NULL;//currentAppIcon;
  wc.hCursor = LoadCursor(NULL, IDC_ARROW);
  wc.hbrBackground = GetStockObject(WHITE_BRUSH); 
  wc.lpszMenuName =  NULL; 
  wc.lpszClassName = "GNUstepWindowClass"; 
  wc.hIconSm = NULL;//currentAppIcon;

  if (!RegisterClassEx(&wc)) 
       return; 

  // FIXME We should use GetSysColor to get standard colours from MS Window and 
  // use them in NSColor

  // Should we create a message only window here, so we can get events, even when
  // no windows are created?
}

- (void) setupRunLoopInputSourcesForMode: (NSString*)mode
{
  NSRunLoop *currentRunLoop = [NSRunLoop currentRunLoop];

#ifdef    __CYGWIN__
  int fdMessageQueue;
#define WIN_MSG_QUEUE_FNAME    "/dev/windows"

  // Open a file descriptor for the windows message queue
  fdMessageQueue = open (WIN_MSG_QUEUE_FNAME, O_RDONLY);
  if (fdMessageQueue == -1)
    {
      NSLog(@"Failed opening %s\n", WIN_MSG_QUEUE_FNAME);
      exit(1);
    }
  [currentRunLoop addEvent: (void*)fdMessageQueue
                  type: ET_RDESC
                  watcher: (id<RunLoopEvents>)self
                  forMode: mode];
#else 
  [currentRunLoop addEvent: (void*)0
                  type: ET_WINMSG
                  watcher: (id<RunLoopEvents>)self
                  forMode: mode];
#endif
}

/**

*/
- (id) initWithAttributes: (NSDictionary *)info
{
//  NSNotificationCenter	*nc = [NSNotificationCenter defaultCenter];

  self = [super initWithAttributes: info];

  if (self)
    {
      [self _initWin32Context];
      [super initWithAttributes: info];

      [self setupRunLoopInputSourcesForMode: NSDefaultRunLoopMode]; 
      [self setupRunLoopInputSourcesForMode: NSConnectionReplyMode]; 
      [self setupRunLoopInputSourcesForMode: NSModalPanelRunLoopMode]; 
      [self setupRunLoopInputSourcesForMode: NSEventTrackingRunLoopMode]; 

      [self setHandlesWindowDecorations: YES];
      [self setUsesNativeTaskbar: YES];

      [GSTheme theme];
      { // Check user defaults
	NSUserDefaults	*defs;
	defs = [NSUserDefaults standardUserDefaults];
   
	if ([defs objectForKey: @"GSUseWMStyles"])
	  {
	    NSWarnLog(@"Usage of 'GSUseWMStyles' as user default option is deprecated. "
		      @"This option will be ignored in future versions. "
		      @"You should use 'GSBackHandlesWindowDecorations' option.");
	    [self setHandlesWindowDecorations: ![defs boolForKey: @"GSUseWMStyles"]];
	  }
	if ([defs objectForKey: @"GSUsesWMTaskbar"])
	  {
	    NSWarnLog(@"Usage of 'GSUseWMTaskbar' as user default option is deprecated. "
		      @"This option will be ignored in future versions. "
		      @"You should use 'GSBackUsesNativeTaskbar' option.");
	    [self setUsesNativeTaskbar: [defs boolForKey: @"GSUseWMTaskbar"]];
	  }

	if ([defs objectForKey: @"GSBackHandlesWindowDecorations"])
	  {
	    [self setHandlesWindowDecorations:
	      [defs boolForKey: @"GSBackHandlesWindowDecorations"]];
	  } 
	if ([defs objectForKey: @"GSBackUsesNativeTaskbar"])
	  {
	    [self setUsesNativeTaskbar:
	      [defs boolForKey: @"GSUseNativeTaskbar"]];
	  }
      }
    }
  return self;
}

- (void) _destroyWin32Context
{
  UnregisterClass("GNUstepWindowClass", hinstance);
}

- (void) dealloc
{
  [self _destroyWin32Context];
  [super dealloc];
}

- (void) restrictWindow: (int)win toImage: (NSImage*)image
{
  //TODO [self subclassResponsibility: _cmd];
}

- (int) findWindowAt: (NSPoint)screenLocation 
           windowRef: (int*)windowRef 
           excluding: (int)win
{
  HWND hwnd;
  POINT p;

  p = GSScreenPointToMS(screenLocation);
  hwnd = WindowFromPoint(p);
  if ((int)hwnd == win)
    {
      /*
       * If the window at the point we want is excluded, 
       * we must look through ALL windows at a lower level
       * until we find one which contains the same point.
       */
      while (hwnd != 0)
        {
          RECT	r;

          hwnd = GetWindow(hwnd, GW_HWNDNEXT);
          GetWindowRect(hwnd, &r);
          if (PtInRect(&r, p) && IsWindowVisible(hwnd))
            {
              break;
            }
        }
    }

  *windowRef = (int)hwnd;	// Any windows

  return (int)hwnd;
}

// FIXME: The following methods wont work for multiple screens
/* Screen information */
- (NSSize) resolutionForScreen: (int)screen
{
  int xres, yres;
  HDC hdc;

  hdc = GetDC(NULL);
  xres = GetDeviceCaps(hdc, LOGPIXELSX);
  yres = GetDeviceCaps(hdc, LOGPIXELSY);
  ReleaseDC(NULL, hdc);
  
  return NSMakeSize(xres, yres);
}

- (NSRect) boundsForScreen: (int)screen
{
  return NSMakeRect(0, 0, GetSystemMetrics(SM_CXSCREEN), 
		    GetSystemMetrics(SM_CYSCREEN));
}

- (NSWindowDepth) windowDepthForScreen: (int)screen
{
  HDC hdc;
  int bits;
  //int planes;
      
  hdc = GetDC(NULL);
  bits = GetDeviceCaps(hdc, BITSPIXEL) / 3;
  //planes = GetDeviceCaps(hdc, PLANES);
  //NSLog(@"bits %d planes %d", bits, planes);
  ReleaseDC(NULL, hdc);
  
  return (_GSRGBBitValue | bits);
}

- (const NSWindowDepth *) availableDepthsForScreen: (int)screen
{
  int		 ndepths = 1;
  NSZone	*defaultZone = NSDefaultMallocZone();
  NSWindowDepth	*depths = 0;

  depths = NSZoneMalloc(defaultZone, sizeof(NSWindowDepth)*(ndepths + 1));
  // FIXME
  depths[0] = [self windowDepthForScreen: screen];
  depths[1] = 0;

  return depths;
}

- (NSArray *) screenList
{
  return [NSArray arrayWithObject: [NSNumber numberWithInt: 0]];
}

/**
   Returns the handle of the module instance.  */
- (void *) serverDevice
{
  return hinstance;
}

/**
   As the number of the window is actually is handle we return this.  */
- (void *) windowDevice: (int)win
{
  return (void *)win;
}

- (void) beep
{
  Beep(400, 500);
}  

/*
  styles are mapped between the two systems 

    NSBorderlessWindowMask      0
    NSTitledWindowMask          1
    NSClosableWindowMask        2
    NSMiniaturizableWindowMask  4
    NSResizableWindowMask       8
    NSIconWindowMask            64
    NSMiniWindowMask            128

  NSMenu(style) =  NSTitledWindowMask | NSClosableWindowMask =3;
*/
- (DWORD) windowStyleForGSStyle: (unsigned int) style
{
  DWORD wstyle = 0;
        
  if ([self handlesWindowDecorations] == NO)
    return WS_POPUP | WS_CLIPCHILDREN;
        
  if (style == 0)
    wstyle = WS_POPUP;
  else
    {
      if ((style & NSTitledWindowMask) == NSTitledWindowMask)
        wstyle |= WS_CAPTION;

      if ((style & NSClosableWindowMask) == NSClosableWindowMask)
        wstyle |= WS_CAPTION + WS_SYSMENU;
      
      if ((style & NSMiniaturizableWindowMask) == NSMiniaturizableWindowMask)
        wstyle |= WS_MINIMIZEBOX + WS_SYSMENU;

      if ((style & NSResizableWindowMask) == NSResizableWindowMask)
        wstyle |= WS_SIZEBOX + WS_MAXIMIZEBOX;

      if (((style & NSMiniWindowMask) == NSMiniWindowMask)
          || ((style & NSIconWindowMask) == NSIconWindowMask))
        wstyle |= WS_ICONIC;

      if (wstyle == 0)
        wstyle = WS_POPUP; //WS_CAPTION+WS_SYSMENU;
   }

   //NSLog(@"Window wstyle %d for style %d", wstyle, style);
   return wstyle | WS_CLIPCHILDREN;
}

- (DWORD) exwindowStyleForGSStyle: (unsigned int) style
{
  DWORD estyle = 0;

  if ((style & NSUtilityWindowMask) == NSUtilityWindowMask)
    {
      // WS_EX_TOOLWINDOW gives windows a thinner frame, like NSUtilityWindowMask
      estyle |= WS_EX_TOOLWINDOW;
    }

  if ([self usesNativeTaskbar])
    {
      // We will put all bordered windows except utility windows in the
      // taskbar. Utility windows don't need to be in the taskbar since
      // they are in the floating window level, so always visible.

      if (style == NSBorderlessWindowMask)
        {
          // WS_EX_TOOLWINDOW also prevents windows from appearing in the taskbar.
          estyle |= WS_EX_TOOLWINDOW;
        }
      else if ((style & NSUtilityWindowMask) == 0)
        {
          // WS_EX_APPWINDOW requests that the window appear in the taskbar
          estyle |= WS_EX_APPWINDOW;
        }
   }
  else /* (NO == [self usesNativeTaskbar]) */
   {
      // Prevent all windows from appearing in the taskbar. As an undesired 
      // side effect this will give all windows with frames thin "tool window" 
      // frames. We could also get rid of the taskbar buttons by creating
      // a hidden window, and setting it as the parent of all other windows, 
      // but that would be more complicated to manage.
      // See http://msdn.microsoft.com/en-us/library/bb776822(v=VS.85).aspx#Managing_Taskbar_But
 
      estyle |= WS_EX_TOOLWINDOW;
    }

  return estyle;
}

- (void) resizeBackingStoreFor: (HWND)hwnd
{
  RECT r;
  WIN_INTERN *win = (WIN_INTERN *)GetWindowLong((HWND)hwnd, GWL_USERDATA);
  
  // FIXME: We should check if the size really did change.
  if (win->useHDC)
    {
      HDC hdc, hdc2;
      HBITMAP hbitmap;
      HGDIOBJ old;
      
      old = SelectObject(win->hdc, win->old);
      DeleteObject(old);
      DeleteDC(win->hdc);
      win->hdc = NULL;
      win->old = NULL;
      
      GetClientRect((HWND)hwnd, &r);
      hdc = GetDC((HWND)hwnd);
      hdc2 = CreateCompatibleDC(hdc);
      hbitmap = CreateCompatibleBitmap(hdc, r.right - r.left, r.bottom - r.top);
      win->old = SelectObject(hdc2, hbitmap);
      win->hdc = hdc2;
      
      ReleaseDC((HWND)hwnd, hdc);

      // After resizing the backing store, we need to redraw the window
      win->backingStoreEmpty = YES;
    }
}

- (BOOL) displayEvent: (unsigned int)uMsg;   // diagnotic filter
{
  [self subclassResponsibility: _cmd];
  return YES;
}

// main event loop

/*
 * Reset all of our flags before the next run through the event switch
 *
 */
- (void) setFlagsforEventLoop: (HWND)hwnd
{
  flags._eventHandled = NO;

  // future house keeping can go here
}

- (LRESULT) windowEventProc: (HWND)hwnd : (UINT)uMsg 
		       : (WPARAM)wParam : (LPARAM)lParam
{ 
  NSEvent *ev = nil;

  [self setFlagsforEventLoop: hwnd];
 
//NSLog(@"event %u", uMsg);
  switch (uMsg) 
    { 
      case WM_SIZING: 
        return [self decodeWM_SIZINGParams: hwnd : wParam : lParam];
	break;
      case WM_NCCREATE: 
        return [self decodeWM_NCCREATEParams: wParam : lParam : hwnd];
        break;
      case WM_NCCALCSIZE: 
        [self decodeWM_NCCALCSIZEParams: wParam : lParam : hwnd]; 
        break;
      case WM_NCACTIVATE: 
        [self decodeWM_NCACTIVATEParams: wParam : lParam : hwnd]; 
        break;
      case WM_NCPAINT: 
        if ([self handlesWindowDecorations])
          [self decodeWM_NCPAINTParams: wParam : lParam : hwnd]; 
        break;
      case WM_SHOWWINDOW: 
      //[self decodeWM_SHOWWINDOWParams: wParam : lParam : hwnd]; 
        break;
      case WM_NCDESTROY: 
        [self decodeWM_NCDESTROYParams: wParam : lParam : hwnd]; 
        break;
      case WM_GETTEXT: 
        [self decodeWM_GETTEXTParams: wParam : lParam : hwnd]; 
        break;
      case WM_STYLECHANGING: 
        break;
      case WM_STYLECHANGED: 
        break;
      case WM_GETMINMAXINFO: 
        return [self decodeWM_GETMINMAXINFOParams: wParam : lParam : hwnd];
        break;
      case WM_CREATE: 
        return [self decodeWM_CREATEParams: wParam : lParam : hwnd];
        break;
      case WM_WINDOWPOSCHANGING: 
        [self decodeWM_WINDOWPOSCHANGINGParams: wParam : lParam : hwnd]; 
        break;
      case WM_WINDOWPOSCHANGED: 
        [self decodeWM_WINDOWPOSCHANGEDParams: wParam : lParam : hwnd]; 
        break;
      case WM_MOVE: 
        return [self decodeWM_MOVEParams: hwnd : wParam : lParam];
        break;
      case WM_MOVING: 
        return [self decodeWM_MOVINGParams: hwnd : wParam : lParam];
        break;
      case WM_SIZE: 
        return [self decodeWM_SIZEParams: hwnd : wParam : lParam];
        break;
      case WM_ENTERSIZEMOVE: 
        break;
      case WM_EXITSIZEMOVE: 
        //return [self decodeWM_EXITSIZEMOVEParams: wParam : lParam : hwnd];
        return DefWindowProc(hwnd, uMsg, wParam, lParam); 
        break; 
      case WM_ACTIVATE: 
        if ((int)lParam !=0)
          [self decodeWM_ACTIVEParams: wParam : lParam : hwnd]; 
        break;
      case WM_ACTIVATEAPP: 
        return [self decodeWM_ACTIVEAPPParams: hwnd : wParam : lParam];
        break;
      case WM_SETFOCUS: 
        return [self decodeWM_SETFOCUSParams: wParam : lParam : hwnd]; 
        break;
      case WM_KILLFOCUS: 
        if (wParam == (int)hwnd)
          return 0;
        else
          [self decodeWM_KILLFOCUSParams: wParam : lParam : hwnd]; 
        break;
      case WM_SETCURSOR: 
        break;
      case WM_QUERYOPEN: 
        [self decodeWM_QUERYOPENParams: wParam : lParam : hwnd]; 
        break;
      case WM_CAPTURECHANGED: 
        [self decodeWM_CAPTURECHANGEDParams: wParam : lParam : hwnd]; 
        break;
      case WM_ERASEBKGND: 
        return [self decodeWM_ERASEBKGNDParams: wParam : lParam : hwnd];
        break;
      case WM_PAINT: 
        [self decodeWM_PAINTParams: (WPARAM)wParam : (LPARAM)lParam : (HWND)hwnd]; 
        break;
      case WM_SYNCPAINT: 
        if ([self handlesWindowDecorations])
          [self decodeWM_SYNCPAINTParams: wParam : lParam : hwnd]; 
        break;
      case WM_CLOSE: 
        [self decodeWM_CLOSEParams: wParam : lParam : hwnd]; 
        break;
      case WM_DESTROY: 
        [self decodeWM_DESTROYParams: wParam : lParam : hwnd];
        break;
      case WM_QUIT: 
        break;
      case WM_USER: 
        break;
      case WM_APP: 
        break;  
      case WM_ENTERMENULOOP: 
        break;
      case WM_EXITMENULOOP: 
        break;
      case WM_INITMENU: 
        break;
      case WM_MENUSELECT: 
        break;
      case WM_ENTERIDLE: 
        break;
      case WM_COMMAND: 
        [self decodeWM_COMMANDParams: wParam : lParam : hwnd];
        break;
      case WM_THEMECHANGED: 
        [self decodeWM_THEMECHANGEDParams: wParam : lParam : hwnd];
        break;
      case WM_SYSKEYDOWN:  //KEYBOARD
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "SYSKEYDOWN", hwnd);
        ev = process_key_event(self, hwnd, wParam, lParam, NSKeyDown);
        break;
      case WM_SYSKEYUP:  //KEYBOARD
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "SYSKEYUP", hwnd);
        ev = process_key_event(self, hwnd, wParam, lParam, NSKeyUp);
        break;
      case WM_SYSCOMMAND: 
        [self decodeWM_SYSCOMMANDParams: wParam : lParam : hwnd];
        break;
      case WM_HELP: 
        break;
      //case WM_GETICON: 
        //return [self decodeWM_GETICONParams: wParam : lParam : hwnd];
        //break;
      //case WM_SETICON: 
        //return [self decodeWM_SETICONParams: wParam : lParam : hwnd];
        //break;
      case WM_CANCELMODE:
        break;
      case WM_ENABLE: 
      case WM_CHILDACTIVATE: 
        break;
      case WM_NULL: 
        break; 
	
      case WM_NCHITTEST: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "NCHITTEST", hwnd);
        break;
      case WM_NCMOUSEMOVE: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "NCMOUSEMOVE", hwnd);
        break;
      case WM_NCLBUTTONDOWN:  //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "NCLBUTTONDOWN", hwnd);
        break;
      case WM_NCLBUTTONUP: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "NCLBUTTONUP", hwnd);
        break;
      case WM_MOUSEACTIVATE: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "MOUSEACTIVATE", hwnd);
        break;
      case WM_MOUSEMOVE: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "MOUSEMOVE", hwnd);
        ev = process_mouse_event(self, hwnd, wParam, lParam, NSMouseMoved, uMsg);
        break;
      case WM_LBUTTONDOWN: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "LBUTTONDOWN", hwnd);
        //[self decodeWM_LBUTTONDOWNParams: (WPARAM)wParam : (LPARAM)lParam : (HWND)hwnd];
        ev = process_mouse_event(self, hwnd, wParam, lParam, NSLeftMouseDown, uMsg);
        break;
      case WM_LBUTTONUP: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "LBUTTONUP", hwnd);
        ev = process_mouse_event(self, hwnd, wParam, lParam, NSLeftMouseUp, uMsg);
        break;
      case WM_LBUTTONDBLCLK: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "LBUTTONDBLCLK", hwnd);
        break;
      case WM_MBUTTONDOWN: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "MBUTTONDOWN", hwnd);
        ev = process_mouse_event(self, hwnd, wParam, lParam, NSOtherMouseDown, uMsg);
        break;
      case WM_MBUTTONUP: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "MBUTTONUP", hwnd);
        ev = process_mouse_event(self, hwnd, wParam, lParam, NSOtherMouseUp, uMsg);
        break;
      case WM_MBUTTONDBLCLK: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "MBUTTONDBLCLK", hwnd);
        break;
      case WM_RBUTTONDOWN: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "RBUTTONDOWN", hwnd);
        ev = process_mouse_event(self, hwnd, wParam, lParam, NSRightMouseDown, uMsg);
        break;
      case WM_RBUTTONUP: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "RBUTTONUP", hwnd);
        ev = process_mouse_event(self, hwnd, wParam, lParam, NSRightMouseUp, uMsg);
        break;
      case WM_RBUTTONDBLCLK: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "RBUTTONDBLCLK", hwnd);
        break;
      case WM_MOUSEHWHEEL: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "MOUSEHWHEEL", hwnd);
        ev = process_mouse_event(self, hwnd, wParam, lParam, NSScrollWheel, uMsg);
        break;
	
      case WM_MOUSEWHEEL: //MOUSE
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "MOUSEWHEEL", hwnd);
        ev = process_mouse_event(self, hwnd, wParam, lParam, NSScrollWheel, uMsg);
        break;
	
      case WM_KEYDOWN:  //KEYBOARD
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "KEYDOWN", hwnd);
        ev = process_key_event(self, hwnd, wParam, lParam, NSKeyDown);
        break;
      case WM_KEYUP:  //KEYBOARD
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "KEYUP", hwnd);
        ev = process_key_event(self, hwnd, wParam, lParam, NSKeyUp);
        break;

      case WM_POWERBROADCAST: //SYSTEM
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "POWERBROADCAST", hwnd);
        break;
      case WM_TIMECHANGE:  //SYSTEM
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "TIMECHANGE", hwnd);
        break;
      case WM_DEVICECHANGE: //SYSTEM
        NSDebugLLog(@"NSEvent", @"Got Message %s for %d", "DEVICECHANGE", hwnd);
        break;
	
      default: 
        // Process all other messages.
          NSDebugLLog(@"NSEvent", @"Got unhandled Message %d for %d", uMsg, hwnd);
          break;
    } 
    
    /*
     * see if the event was handled in the the main loop or in the
     * menu loop.  if eventHandled = YES then we are done and need to
     * tell the windows event handler we are finished 
     */
  if (flags._eventHandled == YES)
    return 0;
  
  if (ev != nil)
    {		
      [GSCurrentServer() postEvent: ev atStart: NO];
      return 0;
    }

  /*
   * We did not care about the event, return it back to the windows
   * event handler 
   */
  return DefWindowProc(hwnd, uMsg, wParam, lParam); 
}

- glContextClass
{
#ifdef HAVE_WGL
  return [Win32GLContext class];
#else
  return nil;
#endif
}

- glPixelFormatClass
{
#ifdef HAVE_WGL
  return [Win32GLPixelFormat class];
#else
  return nil;
#endif
}

@end



@implementation WIN32Server (WindowOps)

/*
  styleMask specifies the receiver's style. It can either be
  NSBorderlessWindowMask, or it can contain any of the following
  options, combined using the C bitwise OR operator: Option Meaning

    NSTitledWindowMask          The NSWindow displays a title bar.
    NSClosableWindowMask        The NSWindow displays a close button.
    NSMiniaturizableWindowMask  The NSWindow displays a miniaturize button. 
    NSResizableWindowMask       The NSWindow displays a resize bar or border.
    NSBorderlessWindowMask
    
    NSBorderlessWindowMask      0
    NSTitledWindowMask          1
    NSClosableWindowMask        2
    NSMiniaturizableWindowMask  4
    NSResizableWindowMask       8
    NSIconWindowMask            64
    NSMiniWindowMask            128

  Borderless windows display none of the usual peripheral elements and
  are generally useful only for display or caching purposes; you
  should normally not need to create them. Also, note that an
  NSWindow's style mask should include NSTitledWindowMask if it
  includes any of the others.

  backingType specifies how the drawing done in the receiver is
  buffered by the object's window device: NSBackingStoreBuffered
  NSBackingStoreRetained NSBackingStoreNonretained


  flag determines whether the Window Server creates a window device
  for the new object immediately. If flag is YES, it defers creating
  the window until the receiver is moved on screen. All display
  messages sent to the NSWindow or its NSViews are postponed until the
  window is created, just before it's moved on screen.  Deferring the
  creation of the window improves launch time and minimizes the
  virtual memory load on the Window Server.  The new NSWindow creates
  an instance of NSView to be its default content view.  You can
  replace it with your own object by using the setContentView: method.

*/

- (int) window: (NSRect)frame : (NSBackingStoreType)type : (unsigned int)style
              : (int) screen
{
  HWND hwnd; 
  RECT r;
  DWORD wstyle;
  DWORD estyle;

  wstyle = [self windowStyleForGSStyle: style];
  estyle = [self exwindowStyleForGSStyle: style];

  r = GSScreenRectToMS(frame);

  NSDebugLLog(@"WTrace", @"window: %@ : %d : %d : %d", NSStringFromRect(frame), 
              type, style, screen);
  NSDebugLLog(@"WTrace", @"         device frame: %d, %d, %d, %d", 
              r.left, r.top, r.right - r.left, r.bottom - r.top);
  hwnd = CreateWindowEx(estyle | WS_EX_LAYERED, 
                        "GNUstepWindowClass", 
                        "GNUstepWindow", 
                        wstyle, 
                        r.left, 
                        r.top, 
                        r.right - r.left, 
                        r.bottom - r.top, 
                        (HWND)NULL, 
                        (HMENU)NULL, 
                        hinstance, 
                        (void*)type);
  NSDebugLLog(@"WCTrace", @"         num/handle: %d", hwnd);
  if (!hwnd) {
    NSLog(@"CreateWindowEx Failed %d", GetLastError());
  }
  
  SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);

  [self _setWindowOwnedByServer: (int)hwnd];
  return (int)hwnd;
}

- (void) termwindow: (int) winNum
{
  NSDebugLLog(@"WCTrace", @"termwindow: %d", winNum);
  if (!DestroyWindow((HWND)winNum)) {
    NSLog(@"DestroyWindow Failed %d", GetLastError());
  }
}

- (void) stylewindow: (unsigned int)style : (int) winNum
{
  DWORD wstyle = [self windowStyleForGSStyle: style];
  DWORD estyle = [self exwindowStyleForGSStyle: style];

  NSAssert([self handlesWindowDecorations], 
	   @"-stylewindow: : called when [self handlesWindowDecorations] == NO");

  NSDebugLLog(@"WTrace", @"stylewindow: %d : %d", style, winNum);
  SetWindowLong((HWND)winNum, GWL_STYLE, wstyle);
  SetWindowLong((HWND)winNum, GWL_EXSTYLE, estyle);
}

- (void) setbackgroundcolor: (NSColor *)color : (int)win
{
}

/** Changes window's the backing store to type */
- (void) windowbacking: (NSBackingStoreType)type : (int) winNum
{
  WIN_INTERN *win = (WIN_INTERN *)GetWindowLong((HWND)winNum, GWL_USERDATA);

  NSDebugLLog(@"WTrace", @"windowbacking: %d : %d", type, winNum);
  if (win->useHDC)
    {
      HGDIOBJ old;

      old = SelectObject(win->hdc, win->old);
      DeleteObject(old);
      DeleteDC(win->hdc);
      win->hdc = NULL;
      win->old = NULL;
      win->useHDC = NO;
    }

  if (type != NSBackingStoreNonretained)
    {
      HDC hdc, hdc2;
      HBITMAP hbitmap;
      RECT r;

      GetClientRect((HWND)winNum, &r);
      hdc = GetDC((HWND)winNum);
      hdc2 = CreateCompatibleDC(hdc);
      hbitmap = CreateCompatibleBitmap(hdc, r.right - r.left, r.bottom - r.top);
      win->old = SelectObject(hdc2, hbitmap);
      win->hdc = hdc2;
      win->useHDC = YES;
      win->backingStoreEmpty = YES;

      ReleaseDC((HWND)winNum, hdc);
    }
  else
    {
      win->useHDC = NO;
      win->hdc = NULL;
    }
}

- (void) titlewindow: (NSString*)window_title : (int) winNum
{
  NSDebugLLog(@"WTrace", @"titlewindow: %@ : %d", window_title, winNum);
  SetWindowTextW((HWND)winNum, (const unichar*)
    [window_title cStringUsingEncoding: NSUnicodeStringEncoding]);
}

- (void) miniwindow: (int) winNum
{
  NSDebugLLog(@"WTrace", @"miniwindow: %d", winNum);
  ShowWindow((HWND)winNum, SW_MINIMIZE); 
}

/** Returns NO as we don't provide mini windows on MS Windows */ 
- (BOOL) appOwnsMiniwindow
{
  return NO;
}

- (void) setWindowdevice: (int)winNum forContext: (NSGraphicsContext *)ctxt
{
  RECT rect;
  float h, l, r, t, b;
  NSWindow *window;

  NSDebugLLog(@"WTrace", @"windowdevice: %d", winNum);
  window = GSWindowWithNumber(winNum);
  GetClientRect((HWND)winNum, &rect);
  h = rect.bottom - rect.top;
  [self styleoffsets: &l : &r : &t : &b : [window styleMask]];
  GSSetDevice(ctxt, (void*)winNum, l, h + b);
  DPSinitmatrix(ctxt);
  DPSinitclip(ctxt);
}

- (void) orderwindow: (int) op : (int) otherWin : (int) winNum
{
  int		flag;
  int		foreground = 0;
  int		otherLevel;
  int		level;
  NSWindow *window = GSWindowWithNumber(winNum);

  NSDebugLLog(@"WTrace", @"orderwindow: %d : %d : %d", op, otherWin, winNum);

  if ([self usesNativeTaskbar])
    {
      /* When using this policy, we make these changes: 
         - don't show the application icon window
         - Never order out the main menu, just minimize it, so that
         when the user clicks on it in the taskbar it will activate the
         application.
      */
      int special;
      special = [[NSApp iconWindow] windowNumber];
      if (winNum == special)
        {
          return;
        }
      special = [[[NSApp mainMenu] window] windowNumber];
      if (winNum == special && op == NSWindowOut)
        {
          ShowWindow((HWND)winNum, SW_MINIMIZE); 
          return;
        }
    }

  if (op == NSWindowOut)
    {
      SetWindowLong((HWND)winNum, OFF_ORDERED, 0);
      SetWindowPos((HWND)winNum, NULL, 0, 0, 0, 0, 
        SWP_HIDEWINDOW | SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
      return;
    }

  if (![window canBecomeMainWindow] && ![window canBecomeKeyWindow]) 
    {   // Bring front, but do not activate, eg - tooltips
    flag = SW_SHOWNA; 
    ShowWindow((HWND)winNum, flag);
    }
  else 
    {
    flag = SW_SHOW;
    
    if (IsIconic((HWND)winNum))
      flag = SW_RESTORE;
    
    ShowWindow((HWND)winNum, flag); 
    }

  SetWindowLong((HWND)winNum, OFF_ORDERED, 1);
  level = GetWindowLong((HWND)winNum, OFF_LEVEL);

  if (otherWin <= 0)
    {
      if (otherWin == 0 && op == NSWindowAbove)
	{
	  /* This combination means we should move to the top of the current
	   * window level but stay below the key window, so if we have a key
	   * window (other than the current window), we store it's id for
	   * testing later.
	   */
	  foreground = (int)GetForegroundWindow();
	  if (foreground < 0 || foreground == winNum)
	    {
	      foreground = 0;
	    }
	}
      otherWin = 0;
    }

  if (otherWin > 0)
    {
      /* Put this on the same window level as the window we are ordering
       * it against.
       */
      otherLevel = GetWindowLong((HWND)otherWin, OFF_LEVEL);
      if (level != otherLevel)
	{
	  NSDebugLLog(@"WTrace",
	    @"orderwindow: implicitly set level of %d (%d) to that of %d (%d)",
	    winNum, level, otherWin, otherLevel);
          level = otherLevel;
	  SetWindowLong((HWND)winNum, OFF_LEVEL, level);
	}
    }

  if (level <= NSDesktopWindowLevel)
    {
      HWND desktop = GetDesktopWindow();

      // For desktop level, put this at the bottom of the z-order
      SetParent((HWND)winNum, desktop);
      otherWin = (int)HWND_BOTTOM;
      NSDebugLLog(@"WTrace",
	@"orderwindow: set %i (%i) to bottom", winNum, level);
    }
  else if (otherWin == 0 || op == NSWindowAbove)
    {
      if (otherWin == 0)
	{
	  /* Start searching from bottom of window list...
	   * The last child of the desktop.
	   */
	  otherWin = (int)GetDesktopWindow();
	  otherWin = (int)GetWindow((HWND)otherWin, GW_CHILD);
	  if (otherWin > 0)
	    {
	      otherWin = (int)GetWindow((HWND)otherWin, GW_HWNDLAST);
	    }
	}
      NSDebugLLog(@"WTrace",
	@"orderwindow: traverse for %d (%d) starting at %d",
	winNum, level, otherWin);
      while (otherWin > 0)
        {
	  TCHAR	buf[32];

	  otherWin = (int)GetNextWindow((HWND)otherWin, GW_HWNDPREV);

	  /* We only look at gnustep windows (other than the one being
	   * ordered) to decide where to place our window.
	   * The assumption is, that if we are ordering a window in,
	   * we want it to be above any non-gnustep window.
	   * FIXME ... perhaps we should move all non-gnustep windows
	   * to be lower than the lowest (excluding gnustep desktop
	   * level windows I suppose) gnustep window.
	   */
	  if (otherWin > 0 && otherWin != winNum
	    && GetClassName((HWND)otherWin, buf, 32) == 18
	    && strncmp(buf, "GNUstepWindowClass", 18) == 0)
	    {
	      if (GetWindowLong((HWND)otherWin, OFF_ORDERED) == 1)
		{
		  otherLevel = GetWindowLong((HWND)otherWin, OFF_LEVEL);
		  NSDebugLLog(@"WTrace",
		    @"orderwindow: found gnustep window %d (%d)",
		    otherWin, otherLevel);
		  if (otherLevel >= level)
		    {
		      if (otherLevel > level)
			{
			  /* On windows, there is no notion of levels, so
			   * native apps will automatically move to the
		           * very top of the stack (above our alert panels etc)
			   *
			   * So to cope with this, when we move to the top
			   * of a level, we assume there may be native apps
			   * above us and we set otherWin=0 to move to the
			   * very top of the stack past them.
			   * 
			   * We rely on the fact that we have code in the
			   * window positioning notification to rearrange
			   * (sort) all the windows into level order if
			   * moving this window to the top messes up the
			   * level ordering.
			   */
			  otherWin = 0;
			  break;
			}
		      if (op == NSWindowBelow || foreground == otherWin)
			{
			  break;
			}
		    }
		}
	    }
	}
    }

  if (otherWin == 0)
    {
      otherWin = (int)HWND_TOP;
      NSDebugLLog(@"WTrace",
	@"orderwindow: set %i (%i) to top", winNum, level);
    }
  else if (otherWin == (int)HWND_BOTTOM)
    {
      NSDebugLLog(@"WTrace",
	@"orderwindow: set %i (%i) to bottom", winNum, level);
    }
  else
    {
      NSDebugLLog(@"WTrace",
	@"orderwindow: set %i (%i) below %d", winNum, level, otherWin);
    }

  SetWindowPos((HWND)winNum, (HWND)otherWin, 0, 0, 0, 0, 
    SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE);

  if (otherWin == (int)HWND_TOP)
    {
      _enableCallbacks = NO;
	  SetForegroundWindow((HWND)winNum);
      _enableCallbacks = YES;
	}
  /* For debug log window stack.
   */
  if (GSDebugSet(@"WTrace") == YES)
    {
      NSString	*s = @"Window list:\n";

      otherWin = (int)GetDesktopWindow();
      otherWin = (int)GetWindow((HWND)otherWin, GW_CHILD);
      if (otherWin > 0)
	{
	  otherWin = (int)GetWindow((HWND)otherWin, GW_HWNDLAST);
	}
      while (otherWin > 0)
	{
	  TCHAR	buf[32];

	  otherWin = (int)GetNextWindow((HWND)otherWin, GW_HWNDPREV);

	  if (otherWin > 0
	    && GetClassName((HWND)otherWin, buf, 32) == 18
	    && strncmp(buf, "GNUstepWindowClass", 18) == 0)
	    {
	      if (GetWindowLong((HWND)otherWin, OFF_ORDERED) == 1)
		{
		  otherLevel = GetWindowLong((HWND)otherWin, OFF_LEVEL);
		  s = [s stringByAppendingFormat:
		    @"%d (%d)\n", otherWin, otherLevel];
		}
	    }
	}
      NSDebugLLog(@"WTrace", @"orderwindow: %@", s);
    }
}

- (void) movewindow: (NSPoint)loc : (int)winNum
{
  POINT p;

  NSDebugLLog(@"WTrace", @"movewindow: %@ : %d", NSStringFromPoint(loc), 
	      winNum);
  p = GSWindowOriginToMS((HWND)winNum, loc);

  SetWindowPos((HWND)winNum, NULL, p.x, p.y, 0, 0, 
               SWP_NOZORDER | SWP_NOSIZE | SWP_NOACTIVATE);
}

- (void) placewindow: (NSRect)frame : (int) winNum
{
  RECT r;
  RECT r2;
  WIN_INTERN *win = (WIN_INTERN *)GetWindowLong((HWND)winNum, GWL_USERDATA);

  NSDebugLLog(@"WTrace", @"placewindow: %@ : %d", NSStringFromRect(frame), 
              winNum);
  r = GSScreenRectToMS(frame);
  GetWindowRect((HWND)winNum, &r2);

  SetWindowPos((HWND)winNum, NULL, 
               r.left, r.top, r.right - r.left, r.bottom - r.top, 
               SWP_NOZORDER | SWP_NOACTIVATE); 

  if ((win->useHDC)
      && (r.right - r.left != r2.right - r2.left)
      && (r.bottom - r.top != r2.bottom - r2.top))
    {
      HDC hdc, hdc2;
      HBITMAP hbitmap;
      HGDIOBJ old;
      
      old = SelectObject(win->hdc, win->old);
      DeleteObject(old);
      DeleteDC(win->hdc);
      win->hdc = NULL;
      win->old = NULL;
      
      GetClientRect((HWND)winNum, &r);
      hdc = GetDC((HWND)winNum);
      hdc2 = CreateCompatibleDC(hdc);
      hbitmap = CreateCompatibleBitmap(hdc, r.right - r.left, r.bottom - r.top);
      win->old = SelectObject(hdc2, hbitmap);
      win->hdc = hdc2;
      
      ReleaseDC((HWND)winNum, hdc);
    }
}

- (BOOL) findwindow: (NSPoint)loc : (int) op : (int) otherWin 
		   : (NSPoint *)floc : (int*) winFound
{
  return NO;
}

- (NSRect) windowbounds: (int) winNum
{
  RECT r;

  GetWindowRect((HWND)winNum, &r);
  return MSScreenRectToGS(r);
}

- (void) setwindowlevel: (int) level : (int) winNum
{
  NSDebugLLog(@"WTrace", @"setwindowlevel: %d : %d", level, winNum);
  if (GetWindowLong((HWND)winNum, OFF_LEVEL) != level)
    {
      SetWindowLong((HWND)winNum, OFF_LEVEL, level);
      if (GetWindowLong((HWND)winNum, OFF_ORDERED) == YES)
	{
          [self orderwindow: NSWindowAbove : 0 : winNum];
	}
    }
}

- (int) windowlevel: (int) winNum
{
  return GetWindowLong((HWND)winNum, OFF_LEVEL);
}

- (NSArray *) windowlist
{
  NSMutableArray	*list = [NSMutableArray arrayWithCapacity: 100];
  HWND			w;
  HWND			next;

  w = GetForegroundWindow();	// Try to start with frontmost window
  if (w == NULL)
    {
      w = GetDesktopWindow();	// This should always succeed.
      w = GetWindow(w, GW_CHILD);
    }

  /* Step up to the frontmost window.
   */
  while ((next = GetNextWindow(w, GW_HWNDPREV)) != NULL)
    {
      w = next;
    }
  
  /* Now walk down the window list populating the array.
   */
  while (w != NULL)
    {
      /* Only add windows we own.
       * FIXME We should improve the API to support all windows on server.
       */
      if (GSWindowWithNumber((int)w) != nil)
	{
	  [list addObject: [NSNumber numberWithInt: (int)w]];
	}
      w = GetNextWindow(w, GW_HWNDNEXT);
    }

  return list;
}

- (int) windowdepth: (int) winNum
{
  return 0;
}

/** Set the maximum size of the window */
- (void) setmaxsize: (NSSize)size : (int) winNum
{
  WIN_INTERN *win = (WIN_INTERN *)GetWindowLong((HWND)winNum, GWL_USERDATA);
  POINT p;

  p.x = size.width;
  p.y = size.height;
  win->minmax.ptMaxTrackSize = p;

  // Disable the maximize box if a maximum size is set
  if (size.width < 10000 || size.height < 10000)
    {
      SetWindowLong((HWND)winNum, GWL_STYLE, 
          GetWindowLong((HWND)winNum, GWL_STYLE) ^ WS_MAXIMIZEBOX);
    }
  else
    {
      SetWindowLong((HWND)winNum, GWL_STYLE, 
          GetWindowLong((HWND)winNum, GWL_STYLE) | WS_MAXIMIZEBOX);
    }
}

/** Set the minimum size of the window */
- (void) setminsize: (NSSize)size : (int) winNum
{
  WIN_INTERN *win = (WIN_INTERN *)GetWindowLong((HWND)winNum, GWL_USERDATA);
  POINT p;

  p.x = size.width;
  p.y = size.height;
  win->minmax.ptMinTrackSize = p;
}

/** Set the resize incremenet of the window */
- (void) setresizeincrements: (NSSize)size : (int) winNum
{
}
/** Causes buffered graphics to be flushed to the screen */
- (void) flushwindowrect: (NSRect)rect : (int)winNum
{
  HWND hwnd = (HWND)winNum;
  RECT r = GSWindowRectToMS(self, hwnd, rect);
  WIN_INTERN *win = (WIN_INTERN *)GetWindowLong(hwnd, GWL_USERDATA);

  if (win->useHDC)
    {
      HDC hdc = GetDC(hwnd);
      WINBOOL result;

      result = BitBlt(hdc, r.left, r.top, 
                      (r.right - r.left), (r.bottom - r.top), 
                      win->hdc, r.left, r.top, SRCCOPY);
      if (!result)
        {
          NSLog(@"Flush window %d %@", hwnd, 
                NSStringFromRect(MSWindowRectToGS(self, hwnd, r)));
          NSLog(@"Flush window failed with %d", GetLastError());
        }
      ReleaseDC(hwnd, hdc);
    }
}

- (void) styleoffsets: (float *) l : (float *) r : (float *) t : (float *) b
		     : (unsigned int) style 
{
  if ([self handlesWindowDecorations])
    {
      DWORD wstyle = [self windowStyleForGSStyle: style];
      DWORD estyle = [self exwindowStyleForGSStyle: style];
      RECT rect = {100, 100, 200, 200};
      
      AdjustWindowRectEx(&rect, wstyle, NO, estyle);

      *l = 100 - rect.left;
      *r = rect.right - 200;
      *t = 100 - rect.top;
      *b = rect.bottom - 200;
      //NSLog(@"Style %d offset %f %f %f %f", wstyle, *l, *r, *t, *b);
    }
  else
    {
      /*
        If we don't handle decorations, all our windows are going to be
        border- and decorationless. In that case, -gui won't call this method, 
        but we still use it internally.
      */
      *l = *r = *t = *b = 0.0;
    }
}

- (void) docedited: (int) edited : (int) winNum
{
}

- (void) setinputstate: (int)state : (int)winNum
{
  if ([self handlesWindowDecorations] == NO)
    {
      return;
    }
  if (state == GSTitleBarMain)
    {
      _enableCallbacks = NO;
      SetActiveWindow((HWND)winNum);
      _enableCallbacks = YES;
    }
}

/** Forces focus to the window so that all key events are sent to this
    window */
- (void) setinputfocus: (int) winNum
{
  NSDebugLLog(@"WTrace", @"setinputfocus: %d", winNum);
  NSDebugLLog(@"Focus", @"Setting input focus to %d", winNum);
  if (winNum == 0)
    {
      NSDebugLLog(@"Focus", @" invalid focus window");
      return;
    }
  if (currentFocus == (HWND)winNum)
    {
      NSDebugLLog(@"Focus", @" window already has focus");
      return;
    }
  desiredFocus = (HWND)winNum;
  SetFocus((HWND)winNum);
}

- (void) setalpha: (float)alpha: (int) win
{
  if (alpha > 0.99)
    {
      SetWindowLong((HWND)win, GWL_EXSTYLE,
                    GetWindowLong((HWND)win, GWL_EXSTYLE) & ~WS_EX_LAYERED);
      RedrawWindow((HWND)win, NULL, NULL, 
                   RDW_ERASE | RDW_INVALIDATE | RDW_FRAME | RDW_ALLCHILDREN);
    }
  else
    {
      SetWindowLong((HWND)win, GWL_EXSTYLE, 
                    GetWindowLong((HWND)win, GWL_EXSTYLE) | WS_EX_LAYERED);
      SetLayeredWindowAttributes((HWND)win, 0, 255 * alpha, LWA_ALPHA);
    }
}

- (NSPoint) mouselocation
{
  POINT p;

  if (!GetCursorPos(&p))
    { 
	  // Try using cursorInfo which should work in more situations
	  CURSORINFO cursorInfo;
	  cursorInfo.cbSize = sizeof(CURSORINFO); 
	  if (!GetCursorInfo(&cursorInfo)) {
		NSLog(@"GetCursorInfo failed with %d", GetLastError());
        return NSZeroPoint;
      }
	  p = cursorInfo.ptScreenPos;
    }

  return MSScreenPointToGS(p.x, p.y);
}

- (NSPoint) mouseLocationOnScreen: (int)screen window: (int *)win
{
  return [self mouselocation];
}

- (BOOL) capturemouse: (int) winNum
{
  NSDebugLLog(@"WTrace", @"capturemouse: %d", winNum);
  SetCapture((HWND)winNum);
  return YES;
}

- (void) releasemouse
{
  NSDebugLLog(@"WTrace", @"releasemouse");
  ReleaseCapture();
}

- (void) hidecursor
{
  NSDebugLLog(@"WTrace", @"hidecursor");
  ShowCursor(NO);
}

- (void) showcursor
{
  ShowCursor(YES);
}

- (void) standardcursor: (int)style : (void **)cid
{
  HCURSOR hCursor = 0;

  NSDebugLLog(@"WTrace", @"standardcursor: %d", style);
  switch (style)
    {
      case GSArrowCursor: 
        hCursor = LoadCursor(NULL, IDC_ARROW);
        break;
      case GSIBeamCursor: 
        hCursor = LoadCursor(NULL, IDC_IBEAM);
        break;
      case GSCrosshairCursor: 
        hCursor = LoadCursor(NULL, IDC_CROSS);
        break;
      case GSPointingHandCursor: 
        hCursor = LoadCursor(NULL, IDC_HAND);
        break;
      case GSResizeLeftRightCursor: 
        hCursor = LoadCursor(NULL, IDC_SIZEWE);
        break;
      case GSResizeUpDownCursor: 
        hCursor = LoadCursor(NULL, IDC_SIZENS);
        break;
      default: 
        return;
    }
  *cid = (void*)hCursor;
}

- (void) imagecursor: (NSPoint)hotp : (NSImage *)image : (void **)cid
{
  /*
    HCURSOR cur;
    BYTE *and;
    BYTE *xor;
    int w, h;

    xor = image;
    cur = CreateCursor(hinstance, (int)hotp.x, (int)hotp.y,  (int)w, (int)h, and, xor);
    *cid = (void*)hCursor;
    */
}

- (void) recolorcursor: (NSColor *)fg : (NSColor *)bg : (void*) cid
{
  /* FIXME The colour is currently ignored
     if (fg != nil)
     {
     ICONINFO iconinfo;

     if (GetIconInfo((HCURSOR)cid, &iconinfo))
     {
     iconinfo.hbmColor = ; 
     }
     }
  */
}

- (void) setcursor: (void*) cid
{
  SetCursor((HCURSOR)cid);
}

- (void) freecursor: (void*) cid
{
  // This is only allowed on non-shared cursors and we have no way of knowing that.
  //DestroyCursor((HCURSOR)cid);
}

- (void) setParentWindow: (int)parentWin 
          forChildWindow: (int)childWin
{
  //SetParent((HWND)childWin, (HWND)parentWin);
}

@end

static unichar 
process_char(WPARAM wParam, unsigned *eventModifierFlags)
{
  switch (wParam)
    {
      case VK_RETURN: return NSCarriageReturnCharacter;
      case VK_TAB:    return NSTabCharacter;
      case VK_ESCAPE:  return 0x1b;
      case VK_BACK:   return NSDeleteCharacter;

	/* The following keys need to be reported as function keys */
  #define WIN_FUNCTIONKEY \
  *eventModifierFlags = *eventModifierFlags | NSFunctionKeyMask;
      case VK_F1: WIN_FUNCTIONKEY return NSF1FunctionKey;
      case VK_F2: WIN_FUNCTIONKEY return NSF2FunctionKey;
      case VK_F3: WIN_FUNCTIONKEY return NSF3FunctionKey;
      case VK_F4: WIN_FUNCTIONKEY return NSF4FunctionKey;
      case VK_F5: WIN_FUNCTIONKEY return NSF5FunctionKey;
      case VK_F6: WIN_FUNCTIONKEY return NSF6FunctionKey;
      case VK_F7: WIN_FUNCTIONKEY return NSF7FunctionKey;
      case VK_F8: WIN_FUNCTIONKEY return NSF8FunctionKey;
      case VK_F9: WIN_FUNCTIONKEY return NSF9FunctionKey;
      case VK_F10: WIN_FUNCTIONKEY return NSF10FunctionKey;
      case VK_F11: WIN_FUNCTIONKEY return NSF12FunctionKey;
      case VK_F12: WIN_FUNCTIONKEY return NSF12FunctionKey;
      case VK_F13: WIN_FUNCTIONKEY return NSF13FunctionKey;
      case VK_F14: WIN_FUNCTIONKEY return NSF14FunctionKey;
      case VK_F15: WIN_FUNCTIONKEY return NSF15FunctionKey;
      case VK_F16: WIN_FUNCTIONKEY return NSF16FunctionKey;
      case VK_F17: WIN_FUNCTIONKEY return NSF17FunctionKey;
      case VK_F18: WIN_FUNCTIONKEY return NSF18FunctionKey;
      case VK_F19: WIN_FUNCTIONKEY return NSF19FunctionKey;
      case VK_F20: WIN_FUNCTIONKEY return NSF20FunctionKey;
      case VK_F21: WIN_FUNCTIONKEY return NSF21FunctionKey;
      case VK_F22: WIN_FUNCTIONKEY return NSF22FunctionKey;
      case VK_F23: WIN_FUNCTIONKEY return NSF23FunctionKey;
      case VK_F24: WIN_FUNCTIONKEY return NSF24FunctionKey;

      case VK_DELETE:      WIN_FUNCTIONKEY return NSDeleteFunctionKey;
      case VK_HOME:        WIN_FUNCTIONKEY return NSHomeFunctionKey;
      case VK_LEFT:        WIN_FUNCTIONKEY return NSLeftArrowFunctionKey;
      case VK_RIGHT:       WIN_FUNCTIONKEY return NSRightArrowFunctionKey;
      case VK_UP:          WIN_FUNCTIONKEY return NSUpArrowFunctionKey;
      case VK_DOWN:        WIN_FUNCTIONKEY return NSDownArrowFunctionKey;
      case VK_PRIOR:       WIN_FUNCTIONKEY return NSPageUpFunctionKey;
      case VK_NEXT:        WIN_FUNCTIONKEY return NSPageDownFunctionKey;
      case VK_END:         WIN_FUNCTIONKEY return NSEndFunctionKey;
      case VK_SELECT:      WIN_FUNCTIONKEY return NSSelectFunctionKey;
      case VK_PRINT:       WIN_FUNCTIONKEY return NSPrintFunctionKey;
      case VK_SNAPSHOT:    WIN_FUNCTIONKEY return NSPrintScreenFunctionKey;
      case VK_EXECUTE:     WIN_FUNCTIONKEY return NSExecuteFunctionKey;
      case VK_INSERT:      WIN_FUNCTIONKEY return NSInsertFunctionKey;
      case VK_HELP:        WIN_FUNCTIONKEY return NSHelpFunctionKey;
      case VK_CANCEL:      WIN_FUNCTIONKEY return NSBreakFunctionKey;
      case VK_MODECHANGE:  WIN_FUNCTIONKEY return NSModeSwitchFunctionKey;
      case VK_SCROLL:      WIN_FUNCTIONKEY return NSScrollLockFunctionKey;
      case VK_PAUSE:       WIN_FUNCTIONKEY return NSPauseFunctionKey;
      case VK_OEM_CLEAR:   WIN_FUNCTIONKEY return NSClearDisplayFunctionKey;
      case VK_CLEAR:       WIN_FUNCTIONKEY return NSClearLineFunctionKey;  
  #undef WIN_FUNCTIONKEY
      default: 
	return 0;
    }
}

static unsigned int
mask_for_keystate(BYTE *keyState)
{
  unsigned int eventFlags = 0;
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
  NSString *firstCommand = [defs stringForKey: @"GSFirstCommandKey"];
  NSString *firstControl = [defs stringForKey: @"GSFirstControlKey"];
  NSString *firstAlt = [defs stringForKey: @"GSFirstAlternateKey"];
  NSString *secondCommand = [defs stringForKey: @"GSSecondCommandKey"];
  NSString *secondControl = [defs stringForKey: @"GSSecondControlKey"];
  NSString *secondAlt = [defs stringForKey: @"GSSecondAlternateKey"];

  /* AltGr is mapped to right alt + left control */ 
  if (keyState[VK_RCONTROL] & 128) // && !((keyState[VK_LCONTROL] & 128) && (keyState[VK_RMENU] & 128))) 
    {
      if([@"Control_R" isEqualToString: firstAlt] ||
	 [@"Control_R" isEqualToString: secondAlt])
	eventFlags |= NSAlternateKeyMask;
      else if([@"Control_R" isEqualToString: firstCommand] ||
	      [@"Control_R" isEqualToString: secondCommand])
	eventFlags |= NSCommandKeyMask;
      else
	eventFlags |= NSControlKeyMask;
    }

  if (keyState[VK_SHIFT] & 128)
    eventFlags |= NSShiftKeyMask;
  if (keyState[VK_CAPITAL] & 128)
    eventFlags |= NSShiftKeyMask;

  if (keyState[VK_MENU] & 128)
    {
      if([@"Alt_R" isEqualToString: firstControl] ||
	 [@"Alt_R" isEqualToString: secondControl])
	eventFlags |= NSControlKeyMask;
      else if([@"Alt_R" isEqualToString: firstCommand] ||
	      [@"Alt_R" isEqualToString: secondCommand])
	eventFlags |= NSCommandKeyMask;
      else
	eventFlags |= NSAlternateKeyMask;
    }

  if (keyState[VK_HELP] & 128)
    eventFlags |= NSHelpKeyMask;

  if ((keyState[VK_LCONTROL] & 128) || (keyState[VK_RWIN] & 128))
    {
      if([@"Control_L" isEqualToString: firstAlt] ||
	 [@"Control_L" isEqualToString: secondAlt])
	eventFlags |= NSAlternateKeyMask;
      else if([@"Control_L" isEqualToString: firstControl] ||
	      [@"Control_L" isEqualToString: secondControl])
	eventFlags |= NSControlKeyMask;
      else
	eventFlags |= NSCommandKeyMask;
    }
  return eventFlags;
}

static NSEvent*
process_key_event(WIN32Server *svr, HWND hwnd, WPARAM wParam, LPARAM lParam, 
		  NSEventType eventType)
{
  NSEvent *event;
  BOOL repeat;
  DWORD pos;
  NSPoint eventLocation;
  unsigned int eventFlags;
  NSTimeInterval time;
  LONG ltime;
  unichar unicode[5];
  unsigned int scan;
  int result;
  BYTE keyState[256];
  NSString *keys, *ukeys;
  NSGraphicsContext *gcontext;
  unichar uChar;

  /* FIXME: How do you guarentee a context is associated with an event? */
  gcontext = GSCurrentContext();

  repeat = (lParam & 0xFFFF) != 0;

  pos = GetMessagePos();
  eventLocation
    = MSWindowPointToGS(svr, hwnd,  GET_X_LPARAM(pos), GET_Y_LPARAM(pos));

  ltime = GetMessageTime();
  time = ltime / 1000.0f;

  GetKeyboardState(keyState);
  eventFlags = mask_for_keystate(keyState);

  switch(wParam)
    {
      case VK_SHIFT: 
      case VK_CAPITAL: 
      case VK_CONTROL: 
      case VK_MENU: 
      case VK_HELP: 
      case VK_NUMLOCK: 
	eventType = NSFlagsChanged;
	break;
      case VK_NUMPAD0: 
      case VK_NUMPAD1: 
      case VK_NUMPAD2: 
      case VK_NUMPAD3: 
      case VK_NUMPAD4: 
      case VK_NUMPAD5: 
      case VK_NUMPAD6: 
      case VK_NUMPAD7: 
      case VK_NUMPAD8: 
      case VK_NUMPAD9: 
	eventFlags |= NSNumericPadKeyMask;
	break;
      default: 
	break;
    }


  uChar = process_char(wParam, &eventFlags);
  if (uChar)
    {
      keys = [NSString  stringWithCharacters: &uChar  length: 1];
      ukeys = [NSString  stringWithCharacters: &uChar  length: 1];
    }
  else
    {
      BYTE blankKeyState[256];
      int i = 0;

      // initialize blank key state array....
      for(i = 0; i < 256; i++)
	blankKeyState[i] = 0;

      scan = ((lParam >> 16) & 0xFF);
      //NSLog(@"Got key code %d %d", scan, wParam);
      result = ToUnicode(wParam, scan, keyState, unicode, 5, 0);
      //NSLog(@"To Unicode resulted in %d with %d", result, unicode[0]);
      if (result == -1)
	{
	  // A non spacing accent key was found, we still try to use the result 
	  result = 1;
	}
      keys = [NSString  stringWithCharacters: unicode length: result];

      // Now get the characters with a blank keyboard state so that
      // no modifiers are applied.
      result = ToUnicode(wParam, scan, blankKeyState, unicode, 5, 0);
      //NSLog(@"To Unicode resulted in %d with %d", result, unicode[0]);
      if (result == -1)
	{
	  // A non spacing accent key was found, we still try to use the result 
	  result = 1;
	}
      
      ukeys = [NSString  stringWithCharacters: unicode  length: result];
    }
  if (eventFlags & NSShiftKeyMask)
    ukeys = [ukeys uppercaseString];
  
  // key events should go to the key window if we have one (Windows' focus window isn't always appropriate)
  int windowNumber = [[NSApp keyWindow] windowNumber];
  if (windowNumber == 0)
    windowNumber  = (int)hwnd;
	
  event = [NSEvent keyEventWithType: eventType
			   location: eventLocation
		      modifierFlags: eventFlags
			  timestamp: time
		       windowNumber: windowNumber
			    context: gcontext
			 characters: keys
		   charactersIgnoringModifiers: ukeys
			  isARepeat: repeat
			    keyCode: wParam];

  return event;
}

static NSEvent*
process_mouse_event(WIN32Server *svr, HWND hwnd, WPARAM wParam, LPARAM lParam, 
		    NSEventType eventType, UINT uMsg)
{
  NSEvent *event;
  NSPoint eventLocation;
  static NSPoint lastLocation = {0.0, 0.0};
  unsigned int eventFlags;
  NSTimeInterval time;
  LONG ltime;
  DWORD tick;
  NSGraphicsContext *gcontext;
  float deltaX = 0.0, deltaY = 0.0;
  static int clickCount = 1;
  static LONG lastTime = 0;
  int clientX, clientY;
/*
 * Occasionally the mouse down events are lost ... don't know why.
 * So we track the mouse status  and simulate mouse down or up events
 * if the button states appear to have changed when we get a move.
 */
  static BOOL lDown = NO;
  static BOOL oDown = NO;
  static BOOL rDown = NO;

  gcontext = GSCurrentContext();

/*
 * Some events give screen coordinates - we must convert those to client
 * coordinates.
 */
  if (eventType == NSScrollWheel)
    {
      POINT point;
      point.x = GET_X_LPARAM(lParam);
      point.y = GET_Y_LPARAM(lParam);
      ScreenToClient(hwnd, &point);
      clientX = point.x;
      clientY = point.y;
    }
  else
    {
      clientX = GET_X_LPARAM(lParam);
      clientY = GET_Y_LPARAM(lParam);
    }

  eventLocation = MSWindowPointToGS(svr, hwnd, clientX, clientY);
  ltime = GetMessageTime();
  time = ltime / 1000.0f;
  tick = GetTickCount();
  eventFlags = 0;
  if (wParam & MK_CONTROL)
    {
      eventFlags |= NSControlKeyMask;
    }
  if (wParam & MK_SHIFT)
    {
      eventFlags |= NSShiftKeyMask;
    }
  if (GetKeyState(VK_MENU) < 0) 
    {
      eventFlags |= NSAlternateKeyMask;
    }
  if (GetKeyState(VK_HELP) < 0) 
    {
      eventFlags |= NSHelpKeyMask;
    }
  // What about other modifiers?

  if (eventType == NSScrollWheel)
    {
      float delta = GET_WHEEL_DELTA_WPARAM(wParam) / 120.0;
      if (uMsg == WM_MOUSEWHEEL)
        deltaY = delta;
      else
        deltaX = delta;
      //NSLog(@"Scroll event with deltaX %f deltaY %f", deltaX, deltaY);
    }
  else if (eventType == NSMouseMoved)
    {
      NSEvent	*e;
      deltaX = eventLocation.x - lastLocation.x;
      deltaY = -(eventLocation.y - lastLocation.y);

      if (wParam & MK_LBUTTON)
        { 
	  if (lDown == NO)
	    {
	      e = process_mouse_event(svr, hwnd, wParam, lParam,
		NSLeftMouseDown, uMsg);
	      [GSCurrentServer() postEvent: e atStart: NO];
	    }
          eventType = NSLeftMouseDragged;
        }
      else if (wParam & MK_RBUTTON)
        {
	  if (lDown == YES)
	    {
	      e = process_mouse_event(svr, hwnd, wParam, lParam,
		NSLeftMouseUp, uMsg);
	      [GSCurrentServer() postEvent: e atStart: NO];
	    }
	  if (rDown == NO)
	    {
	      e = process_mouse_event(svr, hwnd, wParam, lParam,
		NSRightMouseDown, uMsg);
	      [GSCurrentServer() postEvent: e atStart: NO];
	    }
          eventType = NSRightMouseDragged;
        }
      else if (wParam & MK_MBUTTON)
        {
	  if (lDown == YES)
	    {
	      e = process_mouse_event(svr, hwnd, wParam, lParam,
		NSLeftMouseUp, uMsg);
	      [GSCurrentServer() postEvent: e atStart: NO];
	    }
	  if (rDown == YES)
	    {
	      e = process_mouse_event(svr, hwnd, wParam, lParam,
		NSRightMouseUp, uMsg);
	      [GSCurrentServer() postEvent: e atStart: NO];
	    }
	  if (oDown == NO)
	    {
	      e = process_mouse_event(svr, hwnd, wParam, lParam,
		NSOtherMouseDown, uMsg);
	      [GSCurrentServer() postEvent: e atStart: NO];
	    }
          eventType = NSOtherMouseDragged;
        }
      else
	{
	  if (lDown == YES)
	    {
	      e = process_mouse_event(svr, hwnd, wParam, lParam,
		NSLeftMouseUp, uMsg);
	      [GSCurrentServer() postEvent: e atStart: NO];
	    }
	  if (rDown == YES)
	    {
	      e = process_mouse_event(svr, hwnd, wParam, lParam,
		NSRightMouseUp, uMsg);
	      [GSCurrentServer() postEvent: e atStart: NO];
	    }
	  if (oDown == YES)
	    {
	      e = process_mouse_event(svr, hwnd, wParam, lParam,
		NSOtherMouseUp, uMsg);
	      [GSCurrentServer() postEvent: e atStart: NO];
	    }
	}
    }
  else if ((eventType == NSLeftMouseDown)
    || (eventType == NSRightMouseDown)
    || (eventType == NSOtherMouseDown))
    {
      // It seems Windows generates duplicate mouse down events on first click in a window
      if (ltime == lastTime) // duplicate event has identical time
	return nil; // ignore it

      static NSPoint lastClick = {0.0, 0.0};
      
      if (lastTime + GetDoubleClickTime() > ltime 
          && fabs(eventLocation.x - lastClick.x) < GetSystemMetrics(SM_CXDOUBLECLK)
          && fabs(eventLocation.y - lastClick.y) < GetSystemMetrics(SM_CYDOUBLECLK))
        {
          clickCount += 1;
        }
      else 
        {
          clickCount = 1;
        }
      lastTime = ltime;  
      lastClick = eventLocation;
        
      SetCapture(hwnd); // capture the mouse to get mouse moved events outside of window
    }
  else if ( ((eventType == NSLeftMouseUp)
    || (eventType == NSRightMouseUp)
    || (eventType == NSOtherMouseUp)) 
	&& !((wParam & MK_LBUTTON) || (wParam & MK_MBUTTON) || (wParam & MK_RBUTTON)) )
	{
	  ReleaseCapture(); // release capture when all mouse buttons are up
	}

  if (eventType == NSLeftMouseDown) lDown = YES;
  if (eventType == NSRightMouseDown) rDown = YES;
  if (eventType == NSOtherMouseDown) oDown = YES;
  if (eventType == NSLeftMouseUp) lDown = NO;
  if (eventType == NSRightMouseUp) rDown = NO;
  if (eventType == NSOtherMouseUp) oDown = NO;
  
  if (eventType == NSMouseMoved) {
    static HWND lastHwnd = 0;
	if (hwnd == lastHwnd && NSEqualPoints(eventLocation, lastLocation))
	  return nil; // mouse hasn't actually moved -- don't generate another event
	// record window and location of this event, to check next mouseMoved event against
	lastHwnd = hwnd;	
  }

  lastLocation = eventLocation;

  event = [NSEvent mouseEventWithType: eventType
			     location: eventLocation
			modifierFlags: eventFlags
			    timestamp: time
			 windowNumber: (int)hwnd
			      context: gcontext
			  eventNumber: tick
			   clickCount: clickCount
			     pressure: 1.0
			 buttonNumber: 0 /* FIXME */
			       deltaX: deltaX
			       deltaY: deltaY
			       deltaZ: 0.];
  
  return event;
}


LRESULT CALLBACK MainWndProc(HWND hwnd, UINT uMsg, 
			     WPARAM wParam, LPARAM lParam)
{
  WIN32Server	*ctxt = (WIN32Server *)GSCurrentServer();
  
  if(_enableCallbacks == NO)
    {
      return (LRESULT)NULL;
    }

  return [ctxt windowEventProc: hwnd : uMsg : wParam : lParam];
}
