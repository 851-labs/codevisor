use std::sync::Mutex;

use iroh::endpoint::transports::{FourTuple, PathSelection, PathSelectionContext, PathSelector};

#[derive(Debug, Default)]
pub struct FirstPathSelector {
    pinned: Mutex<Option<FourTuple>>,
}

impl PathSelector for FirstPathSelector {
    fn select(&self, ctx: &PathSelectionContext<'_>) -> PathSelection {
        let mut selection = PathSelection::none();
        if ctx.current().is_some() {
            return selection;
        }
        let mut pinned = self.pinned.lock().expect("pinned path lock");
        let path = match pinned.as_ref() {
            Some(first) => ctx.paths().find(|path| path.network_path() == first),
            None => ctx.paths().next(),
        };
        if let Some(path) = path {
            pinned.get_or_insert_with(|| path.network_path().clone());
            selection.set(&path);
        }
        selection
    }
}
