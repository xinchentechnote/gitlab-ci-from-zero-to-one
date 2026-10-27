#include <cstdlib>
#include <iostream>
#include <string>

#include "greeter.hpp"

int main(int argc, char *argv[]) {
  const std::string audience = argc > 1 ? argv[1] : "GitLab CI";
  const char *environment = std::getenv("CI_ENVIRONMENT_SLUG");
  std::cout << greet(audience) << " (v" << HELLO_VERSION << ", "
            << (environment ? environment : "local") << ")" << std::endl;
  return 0;
}
