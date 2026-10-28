#pragma once
#include "Game.hpp"

namespace drift {
struct V3 {float x,y,z;};
struct Vertex {float position[4],normal[4],color[4];};
struct Matrix {float m[16];};
struct Frame {Matrix viewProjection;std::vector<Vertex> vertices;};
// Shared geometry and camera. Platform renderers only submit these triangles.
Frame makeFrame(const Game& game,float aspect);
}
