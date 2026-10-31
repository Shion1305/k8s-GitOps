fn format_answer() -> String {
    let mut buffer = itoa::Buffer::new();
    buffer.format(42).to_owned()
}

fn main() {
    println!("{}", format_answer());
}

#[cfg(test)]
mod tests {
    use super::format_answer;

    #[test]
    fn formats_an_integer() {
        assert_eq!(format_answer(), "42");
    }
}
