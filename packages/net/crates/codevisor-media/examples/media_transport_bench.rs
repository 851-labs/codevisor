#[tokio::main]
async fn main() -> anyhow::Result<()> {
    print!("{}", codevisor_media::bench::run(std::env::args().skip(1).collect()).await?);
    Ok(())
}
