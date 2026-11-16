const deepElements =
  "const deepElements=root=>{const found=[];for(const element of root.querySelectorAll('*')){found.push(element);if(element.shadowRoot)found.push(...deepElements(element.shadowRoot));}return found;};"

const deepQuery =
  "const deepQuery=(root,selector)=>{const matched=new Set(root.querySelectorAll(selector));const found=[];for(const element of root.querySelectorAll('*')){if(matched.has(element))found.push(element);if(element.shadowRoot)found.push(...deepQuery(element.shadowRoot,selector));}return found;};"

const textMatcher =
  "const normalize=value=>String(value??'').replace(/\\s+/g,' ').trim();const matches=value=>{const actual=normalize(value);if(expected&&typeof expected==='object'&&typeof expected.regex==='string')return new RegExp(expected.regex,expected.flags||'').test(actual);return exact?actual===expected:actual.toLocaleLowerCase().includes(String(expected).toLocaleLowerCase());};"

const labelMatches =
  "const labelled=element=>{const tree=element.getRootNode();const labelledBy=(element.getAttribute('aria-labelledby')||'').split(/\\s+/).filter(Boolean).map(id=>tree.getElementById?.(id)?.innerText||'').join(' ');const labels=element.labels?[...element.labels].map(label=>{const clone=label.cloneNode(true);clone.querySelectorAll('input,textarea,select,button,option,[contenteditable=true]').forEach(control=>control.remove());return clone.textContent||'';}):[];return[element.getAttribute('aria-label'),labelledBy,...labels].some(matches);};"

const textMatches =
  "const text=element=>element.matches('script,style,noscript,template')?'':element.innerText||element.textContent;const innermost=element=>![...element.children,...(element.shadowRoot?.children??[])].some(child=>matches(text(child)));"

export const cssLocatorFunction = `function(selector){${deepQuery}return [...(this.shadowRoot?deepQuery(this.shadowRoot,selector):[]),...deepQuery(this,selector)];}`

export const semanticLocatorFunction = `function(kind,expected,exact){${deepElements}${textMatcher}${labelMatches}${textMatches}const elements=[...(this.shadowRoot?deepElements(this.shadowRoot):[]),...deepElements(this)];if(kind==='label')return elements.filter(element=>element.matches('input,textarea,select,button,[contenteditable=true]')&&labelled(element));if(kind==='placeholder')return elements.filter(element=>element.hasAttribute('placeholder')&&matches(element.getAttribute('placeholder')));if(kind==='testId')return elements.filter(element=>element.hasAttribute('data-testid')&&matches(element.getAttribute('data-testid')));if(kind==='altText')return elements.filter(element=>element.hasAttribute('alt')&&matches(element.getAttribute('alt')));if(kind==='title')return elements.filter(element=>element.hasAttribute('title')&&matches(element.getAttribute('title')));return elements.filter(element=>matches(text(element))&&innermost(element)).slice(0,200);}`
