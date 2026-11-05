use std::{env, fs, path::PathBuf, process::Command};

fn output(command: &mut Command) -> String {
    let result = command.output().expect("run build metadata command");
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    String::from_utf8(result.stdout).expect("UTF-8 build metadata")
}

fn dependency<'a>(
    metadata: &'a serde_json::Value,
    package: &serde_json::Value,
    name: &str,
) -> &'a serde_json::Value {
    let node = metadata["resolve"]["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|node| node["id"] == package["id"])
        .expect("resolved package");
    let dep = node["deps"]
        .as_array()
        .unwrap()
        .iter()
        .find(|dep| dep["name"] == name)
        .expect("resolved dependency");
    metadata["packages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|package| package["id"] == dep["pkg"])
        .expect("dependency package")
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=CARGO_TARGET_DIR");
    println!("cargo:rerun-if-env-changed=CARGO_UNSTABLE_BUILD_STD");
    let rustc = env::var_os("RUSTC").expect("RUSTC");
    let version = output(Command::new(&rustc).arg("--version"));
    println!(
        "cargo:rustc-env=SUITE_RUST_VERSION={}",
        version.trim().trim_start_matches("rustc ")
    );

    // A bundle resolves its dependencies in a different workspace from this crate.
    let manifest = env::var_os("CARGO_TARGET_DIR")
        .and_then(|target| {
            PathBuf::from(target)
                .parent()
                .map(|root| root.join("bundle/Cargo.toml"))
        })
        .filter(|manifest| manifest.is_file())
        .unwrap_or_else(|| {
            PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("Cargo.toml")
        });
    let metadata: serde_json::Value = serde_json::from_str(&output(
        Command::new(env::var_os("CARGO").expect("CARGO"))
            .args([
                "metadata",
                "--format-version=1",
                "--locked",
                "--offline",
                "--filter-platform",
            ])
            .arg(env::var_os("TARGET").expect("Cargo target"))
            .arg("--manifest-path")
            .arg(&manifest),
    ))
    .expect("Cargo metadata");
    let workspace = PathBuf::from(metadata["workspace_root"].as_str().unwrap());
    println!(
        "cargo:rerun-if-changed={}",
        workspace.join("Cargo.lock").display()
    );
    let own_manifest = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("Cargo.toml");
    let package = metadata["packages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["manifest_path"].as_str() == own_manifest.to_str())
        .expect("suite package");
    let rustler = dependency(&metadata, package, "rustler");
    let inventory = dependency(&metadata, rustler, "inventory");
    for (name, package) in [("inventory", inventory), ("rustler", rustler)] {
        println!(
            "cargo:rerun-if-changed={}",
            package["manifest_path"].as_str().unwrap()
        );
        println!(
            "cargo:rustc-env=SUITE_{}_VERSION={}",
            name.to_uppercase(),
            package["version"].as_str().unwrap()
        );
    }

    // libc belongs to std's build-std graph, not necessarily the application graph.
    let libc = if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("rtems")
        && env::var_os("CARGO_UNSTABLE_BUILD_STD").is_some()
    {
        let sysroot = output(Command::new(&rustc).args(["--print", "sysroot"]));
        let lock = PathBuf::from(sysroot.trim()).join("lib/rustlib/src/rust/library/Cargo.lock");
        println!("cargo:rerun-if-changed={}", lock.display());
        let lock: toml::Value = toml::from_str(&fs::read_to_string(lock).expect("std Cargo.lock"))
            .expect("std lock TOML");
        lock["package"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["name"].as_str() == Some("libc"))
            .expect("std libc package")["version"]
            .as_str()
            .unwrap()
            .to_owned()
    } else if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("rtems") {
        let sysroot = output(Command::new(&rustc).args(["--print", "sysroot"]));
        let sources = PathBuf::from(sysroot.trim()).join("share/rust-nif/sources.json");
        println!("cargo:rerun-if-changed={}", sources.display());
        let source: serde_json::Value = serde_json::from_slice(
            &fs::read(sources).expect("SDK source provenance"),
        )
        .expect("SDK source JSON");
        source["components"]["libc"]["version"]
            .as_str()
            .expect("SDK libc version")
            .to_owned()
    } else {
        "unknown (prebuilt std)".to_owned()
    };
    println!("cargo:rustc-env=SUITE_LIBC_VERSION={libc}");
}
