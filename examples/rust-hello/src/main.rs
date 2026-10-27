fn greet(name: &str) -> String {
    format!("hello, {}!", name)
}

fn main() {
    let audience = std::env::args().nth(1).unwrap_or_else(|| "GitLab CI".to_string());
    println!(
        "{} (v{}, {})",
        greet(&audience),
        env!("CARGO_PKG_VERSION"),
        std::env::var("CI_ENVIRONMENT_SLUG").unwrap_or_else(|_| "local".to_string())
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn greet_names_the_caller() {
        assert_eq!(greet("rust"), "hello, rust!");
    }
}
