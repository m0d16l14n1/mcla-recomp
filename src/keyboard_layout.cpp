// Keyboard layouts for the SDK's keyboard controller (--mnk_mode=true).
//
// The SDK maps keys to controller buttons through its keybind_* options, laid
// out for a controller-shaped hand: the right trigger (gas) on E and O, the
// left stick on WASD. That is awkward for a driving game, so "driving" (the
// default) puts gas and brake on W and S (and the arrow keys), steering on A
// and D, and the face buttons on the letters of their on-screen prompts where
// those are free (X, Y, B). Only options still at the SDK's default change: a
// keybind_* the player set (command line or config) stays as it is.
//
// The actions are those the game's own drive scripts give the buttons
// (launcher/dev/scripts/arcade-race.pad, TOUR): X nitro, RB camera view,
// Y headlights, LB special ability, A handbrake, right stick press horn,
// d-pad up the overhead map.

#include <string>
#include <utility>

#include <rex/cvar.h>
#include <rex/logging.h>

REXCVAR_DEFINE_STRING(mcla_keyboard_layout, "driving", "MCLA",
                      "Keyboard layout with --mnk_mode=true: driving (W gas, S brake, A and D "
                      "steer, the arrow keys the same) or controller (the SDK's keybind_* "
                      "defaults: gas on E, WASD the left stick). A keybind_* set by hand wins")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

void MclaApplyKeyboardLayout() {
  const std::string layout = REXCVAR_GET(mcla_keyboard_layout);
  if (layout != "driving") {
    if (layout != "controller") {
      REXLOG_WARN("keyboard: unknown mcla_keyboard_layout '{}'; the SDK's layout is used", layout);
    }
    return;
  }
  // A key in two binds presses both: W is gas and the left stick's up, so that
  // the same key moves through menus. Binds match modifiers exactly, so Shift
  // plus an arrow stays the d-pad, as in the SDK's layout.
  constexpr std::pair<const char*, const char*> kDriving[] = {
      {"keybind_right_trigger", "W,Up"},
      {"keybind_left_trigger", "S,Down"},
      {"keybind_lstick_up", "W,Up"},
      {"keybind_lstick_down", "S,Down"},
      {"keybind_lstick_left", "A,Left"},
      {"keybind_lstick_right", "D,Right"},
      {"keybind_rstick_up", "I"},
      {"keybind_rstick_down", "K"},
      {"keybind_rstick_left", "J"},
      {"keybind_rstick_right", "L"},
      {"keybind_a", "Space"},
      {"keybind_b", "B,Backspace"},
      {"keybind_x", "X,N"},
      {"keybind_y", "Y"},
      {"keybind_left_shoulder", "Q"},
      {"keybind_right_shoulder", "E,C"},
      {"keybind_lstick_press", "F"},
      {"keybind_rstick_press", "H"},
      {"keybind_dpad_up", "M,Shift+Up"},
      {"keybind_dpad_down", "Shift+Down"},
      {"keybind_dpad_left", "Shift+Left"},
      {"keybind_dpad_right", "Shift+Right"},
      {"keybind_back", "Tab"},
      {"keybind_start", "Escape,Return"},
  };
  int kept = 0;
  for (const auto& [name, keys] : kDriving) {
    if (rex::cvar::GetFlagSource(name) != rex::cvar::Source::kDefault) {
      ++kept;
      continue;
    }
    if (!rex::cvar::SetDefaultValue(name, keys)) {
      REXLOG_WARN("keyboard: {} = {} not taken (this SDK has no such option)", name, keys);
    }
  }
  REXLOG_INFO("keyboard: driving layout, {} keys set by hand kept", kept);
}
