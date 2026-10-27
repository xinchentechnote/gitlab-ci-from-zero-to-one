#include <iostream>

#include "greeter.hpp"

int main() {
  if (greet("cpp") != "hello, cpp!") {
    std::cerr << "greet(\"cpp\") returned \"" << greet("cpp") << "\"" << std::endl;
    return 1;
  }
  std::cout << "greeter ok" << std::endl;
  return 0;
}
