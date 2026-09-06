fn main() {
    std::process::exit(cmux_cli::run(std::env::args().skip(1).collect(), cmux_cli::Program::Cmux));
}
