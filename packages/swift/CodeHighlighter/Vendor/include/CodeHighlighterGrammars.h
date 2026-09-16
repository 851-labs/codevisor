#ifndef CODEHIGHLIGHTER_GRAMMARS_H
#define CODEHIGHLIGHTER_GRAMMARS_H
typedef struct TSLanguage TSLanguage;
#define CV_GRAMMAR(name) const TSLanguage *tree_sitter_##name(void);
CV_GRAMMAR(bash)
CV_GRAMMAR(c)
CV_GRAMMAR(cpp)
CV_GRAMMAR(css)
CV_GRAMMAR(diff)
CV_GRAMMAR(go)
CV_GRAMMAR(html)
CV_GRAMMAR(java)
CV_GRAMMAR(javascript)
CV_GRAMMAR(json)
CV_GRAMMAR(kotlin)
CV_GRAMMAR(markdown)
CV_GRAMMAR(markdown_inline)
CV_GRAMMAR(python)
CV_GRAMMAR(ruby)
CV_GRAMMAR(rust)
CV_GRAMMAR(sql)
CV_GRAMMAR(swift)
CV_GRAMMAR(toml)
CV_GRAMMAR(tsx)
CV_GRAMMAR(typescript)
CV_GRAMMAR(yaml)
#undef CV_GRAMMAR
#endif
