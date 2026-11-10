void main() {
  thirdLevel();
}

void thirdLevel() {
  secondLevel();
}

void secondLevel() {
  throw StateError('fixture crash for symbolize tests');
}
