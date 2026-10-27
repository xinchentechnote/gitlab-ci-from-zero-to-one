package com.example;

public final class Hello {
    private Hello() {}

    static String greet(String name) {
        return "hello, " + name + "!";
    }

    public static void main(String[] args) {
        String audience = args.length > 0 ? args[0] : "GitLab CI";
        String version = Hello.class.getPackage().getImplementationVersion();
        String environment = System.getenv("CI_ENVIRONMENT_SLUG");
        System.out.printf("%s (v%s, %s)%n",
                greet(audience),
                version == null ? "unknown" : version,
                environment == null ? "local" : environment);
    }
}
