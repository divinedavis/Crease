'use client';

import { useEffect, useRef, useState } from 'react';

export interface Suggestion {
  label: string;
  borough: string | null;
  lat: number;
  lng: number;
}

/**
 * The address field, with the city's own suggestions underneath it.
 *
 * Typing a full address into a plain box is the slowest thing on this page and
 * the easiest to get wrong — a misspelt street is a geocode miss, which reads
 * to the customer as "we don't serve you". Three characters is where the list
 * becomes short enough to be worth showing.
 *
 * Picking a suggestion carries its coordinates through with it, so the server
 * never has to geocode a string it already has a point for.
 */
export function AddressField({
  name = 'address',
  placeholder = 'Enter pickup address',
  defaultValue = '',
  autoFocus = false,
}: {
  name?: string;
  placeholder?: string;
  defaultValue?: string;
  autoFocus?: boolean;
}) {
  const [value, setValue] = useState(defaultValue);
  const [items, setItems] = useState<Suggestion[]>([]);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  const [picked, setPicked] = useState<Suggestion | null>(null);
  const box = useRef<HTMLDivElement>(null);

  // Debounced, because a request per keystroke is a request per keystroke —
  // for the city's free service and for the person on a phone paying for the
  // data. 220ms is under the gap between two typed characters.
  useEffect(() => {
    const q = value.trim();
    if (picked && q === picked.label) return;
    if (q.length < 3) {
      setItems([]);
      return;
    }
    const ctrl = new AbortController();
    const timer = setTimeout(async () => {
      try {
        const res = await fetch(`/api/address?q=${encodeURIComponent(q)}`, {
          signal: ctrl.signal,
        });
        if (!res.ok) return;
        const body = await res.json();
        setItems(body.suggestions ?? []);
        setOpen(true);
        setActive(-1);
      } catch {
        // An aborted or failed lookup leaves whatever they typed alone.
      }
    }, 220);
    return () => {
      clearTimeout(timer);
      ctrl.abort();
    };
  }, [value, picked]);

  // A dropdown that outlives the click that dismissed it is a dropdown over
  // the button somebody was trying to press.
  useEffect(() => {
    function away(e: MouseEvent) {
      if (box.current && !box.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener('mousedown', away);
    return () => document.removeEventListener('mousedown', away);
  }, []);

  function choose(s: Suggestion) {
    setPicked(s);
    setValue(s.label);
    setItems([]);
    setOpen(false);
    setActive(-1);
  }

  function onKey(e: React.KeyboardEvent<HTMLInputElement>) {
    if (!open || items.length === 0) return;
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      setActive((i) => (i + 1) % items.length);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setActive((i) => (i <= 0 ? items.length - 1 : i - 1));
    } else if (e.key === 'Enter' && active >= 0) {
      // Only steals Enter when something is highlighted; otherwise the form
      // submits, which is what somebody typing their own address expects.
      e.preventDefault();
      choose(items[active]);
    } else if (e.key === 'Escape') {
      setOpen(false);
    }
  }

  return (
    <div className="ac" ref={box}>
      <div className="field">
        <span className="dot" aria-hidden="true" />
        <input
          name={name}
          value={value}
          onChange={(e) => {
            setValue(e.target.value);
            setPicked(null);
          }}
          onFocus={() => items.length && setOpen(true)}
          onKeyDown={onKey}
          placeholder={placeholder}
          aria-label="Pickup address in Brooklyn"
          autoComplete="off"
          role="combobox"
          aria-expanded={open}
          aria-autocomplete="list"
          aria-controls="ac-list"
          autoFocus={autoFocus}
          required
        />
      </div>

      {/* The coordinates travel with the choice, so the server does not
          re-geocode a string it already has a point for. */}
      <input type="hidden" name="lat" value={picked?.lat ?? ''} />
      <input type="hidden" name="lng" value={picked?.lng ?? ''} />

      {open && items.length > 0 && (
        <ul className="ac-list" id="ac-list" role="listbox">
          {items.map((s, i) => (
            <li
              key={s.label + i}
              role="option"
              aria-selected={i === active}
              className={i === active ? 'on' : ''}
              onMouseEnter={() => setActive(i)}
              // mousedown, not click: the input's blur would close the list
              // before a click ever landed.
              onMouseDown={(e) => {
                e.preventDefault();
                choose(s);
              }}
            >
              <span className="ac-label">{s.label}</span>
              {s.borough && s.borough !== 'Brooklyn' && (
                <span className="ac-note">{s.borough}</span>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
