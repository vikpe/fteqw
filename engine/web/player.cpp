#include <emscripten/bind.h>
#include "quakedef.h"

using namespace emscripten;

val player_info() {
  std::vector<val> vect;

  for (auto i = 0; i < cl.allocated_client_slots; ++i) {
    auto player = &cl.players[i];
    if (player->spectator == 1) {
      continue;
    }

    const char *name = player->name;
    const char *team = player->team;

    if (!name[0]) {
      continue;
    }


    val p(val::object());
    p.set("name", val(name));
    p.set("team", val(team));
    p.set("frags", val(player->frags));

    vect.push_back(p);
  }

  val rv(val::array(vect));
  return rv;
}


EMSCRIPTEN_BINDINGS(fte) {
  function("player_info", &player_info);
}
