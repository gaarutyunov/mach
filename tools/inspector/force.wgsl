// Force-directed graph layout, one simulation step per dispatch, one invocation per node.
//
// Nodes keep their column (x) from the layered layout, and the simulation arranges each column
// vertically:
// * repulsion from the other nodes of the same column, and no overlapping (`spring_len` apart)
// * springs along edges pull a node to the height of its neighbors (clusters relations)
// * gravity towards y = 0 keeps the columns compact
//
// Positions are box centers. Nodes are read from `nodes_in` and written to `nodes_out`; the app
// ping-pongs between two buffers.

struct Params {
  count: u32,
  edge_count: u32,
  alpha: f32,
  repulsion: f32,
  spring_len: f32,
  spring_k: f32,
  gravity: f32,
  damping: f32,
  flow: f32,
  max_speed: f32,
  _pad0: u32,
  _pad1: u32,
};

struct Node {
  pos: vec2<f32>,
  vel: vec2<f32>,
  half: vec2<f32>,
  pinned: u32,
  _pad: u32,
};

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read> nodes_in: array<Node>;
@group(0) @binding(2) var<storage, read_write> nodes_out: array<Node>;
// Node i's neighbors are adj[adj_offsets[i] .. adj_offsets[i + 1]]: a node index, with the top
// bit set if i is the edge's source (else its target).
@group(0) @binding(3) var<storage, read> adj_offsets: array<u32>;
@group(0) @binding(4) var<storage, read> adj: array<u32>;

@compute @workgroup_size(64)
fn step(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  if (i >= params.count) {
    return;
  }
  var node = nodes_in[i];
  if (node.pinned != 0u) {
    node.vel = vec2<f32>(0.0, 0.0);
    nodes_out[i] = node;
    return;
  }

  // Columns are kept: nodes only move vertically. x stays where the layered layout (or the
  // user, by dragging) put the node, so data still flows left to right.
  var force: f32 = 0.0;

  // Repulsion and collisions, only between nodes of the same column.
  for (var j = 0u; j < params.count; j = j + 1u) {
    if (j == i) {
      continue;
    }
    let other = nodes_in[j];
    if (abs(node.pos.x - other.pos.x) >= node.half.x + other.half.x + 20.0) {
      continue;
    }
    var dy = node.pos.y - other.pos.y;
    if (abs(dy) < 0.01) {
      // Coincident nodes: separate them deterministically.
      dy = (f32(i) - f32(j)) * 0.01;
    }
    // sign(dy): sysgpu's shader compiler lacks sign() on f32.
    let dir = dy / max(abs(dy), 0.0001);
    let dist = abs(dy);
    force = force + dir * (params.repulsion / max(dist, 1.0));
    let gap = dist - (node.half.y + other.half.y + params.spring_len);
    if (gap < 0.0) {
      force = force - dir * gap * 2.0;
    }
  }

  // Springs along edges pull a node to the height of its neighbors, so related nodes line up and
  // edges run straight.
  let start = adj_offsets[i];
  let end = adj_offsets[i + 1u];
  for (var e = start; e < end; e = e + 1u) {
    let j = adj[e] & 0x7fffffffu;
    force = force + (nodes_in[j].pos.y - node.pos.y) * params.spring_k;
  }

  // Gravity keeps the columns compact around the middle.
  force = force - node.pos.y * params.gravity;

  var vel = vec2<f32>(0.0, (node.vel.y + force * params.alpha) * params.damping);
  let speed = length(vel);
  if (speed > params.max_speed) {
    vel = vel * (params.max_speed / speed);
  }
  node.vel = vel;
  node.pos = node.pos + vel;
  nodes_out[i] = node;
}
