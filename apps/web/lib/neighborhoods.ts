/**
 * What three miles from 909 Fulton Street actually covers.
 *
 * Measured, not guessed: every dry cleaner and laundromat in the Brooklyn
 * canvass carries coordinates, and thirty NYC neighbourhoods have at least one
 * of them inside the band. Naming only Clinton Hill and Fort Greene sold the
 * area far shorter than it is — Downtown Brooklyn is 0.7 miles out, Park Slope
 * 0.5, Williamsburg 1.9.
 *
 * Grouped by how much of each is inside, because "we deliver to Sunset Park"
 * is a promise that breaks at 42nd Street. The address check is the authority;
 * this list is what somebody reads before they bother typing.
 */
export interface Area {
  name: string;
  /** Distance from the shop to the nearest measured point in it, in miles. */
  miles: number;
}

/** Comfortably inside the band, centre and edges. */
export const CORE_AREAS: Area[] = [
  { name: 'Clinton Hill', miles: 0 },
  { name: 'Prospect Heights', miles: 0.2 },
  { name: 'Fort Greene', miles: 0.4 },
  { name: 'Bedford-Stuyvesant', miles: 0.5 },
  { name: 'Park Slope', miles: 0.5 },
  { name: 'Downtown Brooklyn', miles: 0.7 },
  { name: 'DUMBO', miles: 0.7 },
  { name: 'Boerum Hill', miles: 0.7 },
  { name: 'Crown Heights', miles: 0.7 },
  { name: 'Gowanus', miles: 1.0 },
  { name: 'Carroll Gardens', miles: 1.0 },
  { name: 'Cobble Hill', miles: 1.0 },
  { name: 'Red Hook', miles: 1.0 },
  { name: 'Brooklyn Heights', miles: 1.4 },
  { name: 'Prospect Lefferts Gardens', miles: 1.4 },
  { name: 'South Williamsburg', miles: 1.6 },
  { name: 'Windsor Terrace', miles: 1.7 },
  { name: 'South Slope', miles: 1.7 },
];

/** Reached, but only in part — the far end of these is outside the band. */
export const EDGE_AREAS: Area[] = [
  { name: 'Williamsburg', miles: 1.9 },
  { name: 'East Williamsburg', miles: 2.0 },
  { name: 'Bushwick', miles: 2.0 },
  { name: 'Flatbush', miles: 2.0 },
  { name: 'Ditmas Park', miles: 2.3 },
  { name: 'Kensington', miles: 2.5 },
  { name: 'East Flatbush', miles: 2.5 },
  { name: 'Ocean Hill', miles: 2.6 },
  { name: 'Greenpoint', miles: 2.9 },
  { name: 'Borough Park', miles: 2.9 },
  { name: 'Sunset Park', miles: 3.0 },
];

/** The short version, for a line of copy rather than a list. */
export const HEADLINE_AREAS = CORE_AREAS.slice(0, 6).map((a) => a.name);
