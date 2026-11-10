import 'dart:math' as math;

void main() {
  outerCall(3);
}

void outerCall(int depth) {
  if (depth <= 0) {
    throw StateError('fixture crash number two');
  }
  innerCall(depth - 1, math.sqrt(depth.toDouble()));
}

void innerCall(int depth, double ignored) {
  outerCall(depth);
}
