mod support;

use std::path::Path;
use syn::visit::Visit;

fn unsafe_syntax_count(source: &str) -> Result<usize, syn::Error> {
    struct Counter(usize);

    impl<'ast> Visit<'ast> for Counter {
        fn visit_attribute(&mut self, attribute: &'ast syn::Attribute) {
            self.0 += usize::from(attribute.path().is_ident("unsafe"));
            syn::visit::visit_attribute(self, attribute);
        }

        fn visit_expr_unsafe(&mut self, expression: &'ast syn::ExprUnsafe) {
            self.0 += 1;
            syn::visit::visit_expr_unsafe(self, expression);
        }

        fn visit_item_foreign_mod(&mut self, item: &'ast syn::ItemForeignMod) {
            self.0 += usize::from(item.unsafety.is_some());
            syn::visit::visit_item_foreign_mod(self, item);
        }

        fn visit_impl_item_fn(&mut self, item: &'ast syn::ImplItemFn) {
            self.0 += usize::from(matches!(item.sig.safety, syn::Safety::Unsafe(_)));
            syn::visit::visit_impl_item_fn(self, item);
        }

        fn visit_item_fn(&mut self, item: &'ast syn::ItemFn) {
            self.0 += usize::from(matches!(item.sig.safety, syn::Safety::Unsafe(_)));
            syn::visit::visit_item_fn(self, item);
        }

        fn visit_item_impl(&mut self, item: &'ast syn::ItemImpl) {
            self.0 += usize::from(item.unsafety.is_some());
            syn::visit::visit_item_impl(self, item);
        }

        fn visit_item_trait(&mut self, item: &'ast syn::ItemTrait) {
            self.0 += usize::from(item.unsafety.is_some());
            syn::visit::visit_item_trait(self, item);
        }

        fn visit_trait_item_fn(&mut self, item: &'ast syn::TraitItemFn) {
            self.0 += usize::from(matches!(item.sig.safety, syn::Safety::Unsafe(_)));
            syn::visit::visit_trait_item_fn(self, item);
        }
    }

    let syntax = syn::parse_file(source)?;
    let mut counter = Counter(0);
    counter.visit_file(&syntax);
    Ok(counter.0)
}

#[test]
fn unsafe_syntax_is_confined_to_ffi() {
    let source_root = support::lane_root().join("kamu-money-pg/src");
    let mut outside_ffi = Vec::new();
    let mut ffi_constructs = 0;

    for path in support::rust_sources_under(&source_root) {
        let source = support::read(&path);
        let count = unsafe_syntax_count(&source)
            .unwrap_or_else(|error| panic!("{} must parse as Rust: {error}", path.display()));
        let relative = path.strip_prefix(&source_root).expect("source must be below src/");
        if relative.starts_with(Path::new("ffi")) {
            ffi_constructs += count;
        } else if count != 0 {
            outside_ffi.push(format!("{} ({count})", relative.display()));
        }
    }

    assert!(ffi_constructs > 0, "positive control: ffi/ must contain the ABI boundary");
    assert!(
        outside_ffi.is_empty(),
        "unsafe syntax is allowed only below src/ffi:\n{}",
        outside_ffi.join("\n")
    );
}

#[test]
fn unsafe_scanner_ignores_prose_and_counts_syntax() {
    let prose = r#"
        //! `unsafe` in documentation is not syntax.
        const WORD: &str = "unsafe fn";
        fn safe() {}
    "#;
    assert_eq!(unsafe_syntax_count(prose).expect("sample must parse"), 0);

    let violation = r#"
        unsafe fn raw() {
            unsafe { core::ptr::read(core::ptr::null::<u8>()); }
        }
    "#;
    assert_eq!(unsafe_syntax_count(violation).expect("sample must parse"), 2);
}

#[test]
fn allocation_checks_length_before_materializing_weights() {
    // The allocate entry point is the `$allocate` arm of `pinned_money_type!`:
    // one definition, 178 instantiations, so the ordering proven here holds for
    // every generated currency.
    let source_root = support::lane_root().join("kamu-money-pg/src");
    let source = support::rust_sources_under(&source_root)
        .into_iter()
        .map(support::read)
        .find(|source| source.lines().any(|line| line.trim_start().starts_with("fn $allocate(")))
        .expect("src/ must define the $allocate macro arm");
    let signature = source
        .lines()
        .find(|line| line.trim_start().starts_with("fn $allocate("))
        .expect("function signature must exist");

    assert!(
        signature.contains("Array<") && !signature.contains("Vec<Option<"),
        "$allocate must borrow pgrx Array so the cap runs before collection: {}",
        signature.trim()
    );

    let body = &source[source.find("fn $allocate(").expect("function must exist")..];
    let body = &body[..body.find("\n}\n").map_or(body.len(), |end| end + 2)];
    let len = body.find(".len()");
    let iter = body.find(".iter()");
    assert!(
        matches!((len, iter), (Some(len), Some(iter)) if len < iter),
        "$allocate must read len before iterating (len={len:?}, iter={iter:?})"
    );
}
