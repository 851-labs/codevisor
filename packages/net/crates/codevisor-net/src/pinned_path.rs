use iroh::endpoint::transports::{PathSelection, PathSelectionContext, PathSelector};

#[derive(Debug, Default)]
pub struct FirstPathSelector;

impl PathSelector for FirstPathSelector {
    fn select(&self, ctx: &PathSelectionContext<'_>) -> PathSelection {
        let mut selection = PathSelection::none();
        if ctx.current().is_none()
            && let Some(path) = ctx.paths().next()
        {
            selection.set(&path);
        }
        selection
    }
}
