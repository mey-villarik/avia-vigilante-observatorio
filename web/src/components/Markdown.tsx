// Markdown mínimo y seguro (sin innerHTML): títulos ####, listas con - o •, y **negrita**.
import type { ReactNode } from 'react';

function inline(text: string): ReactNode[] {
  return text.split(/(\*\*[^*]+\*\*)/g).map((part, i) =>
    part.startsWith('**') && part.endsWith('**') ? <b key={i}>{part.slice(2, -2)}</b> : part);
}

export function Markdown({ text }: { text: string }) {
  const out: ReactNode[] = [];
  let list: ReactNode[] = [];
  const flush = () => {
    if (list.length) out.push(<ul key={'u' + out.length}>{list}</ul>);
    list = [];
  };
  text.split('\n').forEach((l, i) => {
    if (/^#{1,4}\s/.test(l)) { flush(); out.push(<h4 key={i}>{inline(l.replace(/^#{1,4}\s/, ''))}</h4>); }
    else if (/^\s*[-*•]\s/.test(l)) list.push(<li key={i}>{inline(l.replace(/^\s*[-*•]\s/, ''))}</li>);
    else { flush(); if (l.trim()) out.push(<p key={i} style={{ margin: '0 0 8px' }}>{inline(l)}</p>); }
  });
  flush();
  return <div style={{ whiteSpace: 'normal' }}>{out}</div>;
}
