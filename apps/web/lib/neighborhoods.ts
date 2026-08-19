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
  /** URL slug for the neighbourhood's own page. */
  slug?: string;
  /** One true sentence about collecting here, for that page's opening. */
  note?: string;
}

/** Lowercase, hyphenated, no punctuation — stable enough to be a URL forever. */
export function slugFor(area: Area): string {
  return (
    area.slug ??
    area.name
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-|-$/g, '')
  );
}

export function findArea(slug: string): Area | undefined {
  return [...CORE_AREAS, ...EDGE_AREAS].find((a) => slugFor(a) === slug);
}

/** Comfortably inside the band, centre and edges. */
export const CORE_AREAS: Area[] = [
  { note: "We wash in Clinton Hill, so this is the shortest trip we make — the bag rarely leaves the neighborhood.", name: 'Clinton Hill', miles: 0 },
  { note: "A few blocks down Vanderbilt. One of the closest neighborhoods we collect from.", name: 'Prospect Heights', miles: 0.2 },
  { note: "Across the park from where we wash. Most Fort Greene pickups are a five-minute drive each way.", name: 'Fort Greene', miles: 0.4 },
  { note: "Bed-Stuy is one of the largest areas inside our band, and every part of the western half is comfortably in it.", name: 'Bedford-Stuyvesant', miles: 0.5 },
  { note: "Half a mile past the park. All of Park Slope sits inside the three-mile band.", name: 'Park Slope', miles: 0.5 },
  { note: "Under a mile out, so a Downtown Brooklyn bag is usually the fastest round trip on the board.", name: 'Downtown Brooklyn', miles: 0.7 },
  { note: "Down the hill and along the water. DUMBO is well inside the band despite feeling like a different borough.", name: 'DUMBO', miles: 0.7 },
  { note: "Between Downtown and Gowanus, and one of the quicker runs we make.", name: 'Boerum Hill', miles: 0.7 },
  { note: "East along Atlantic. Both the north and south sides of Crown Heights are inside the band.", name: 'Crown Heights', miles: 0.7 },
  { note: "Over the canal and back. A mile away as the driver drives.", name: 'Gowanus', miles: 1.0 },
  { note: "Past Gowanus, still comfortably inside. Brownstones without in-unit laundry are our most common Carroll Gardens customer.", name: 'Carroll Gardens', miles: 1.0 },
  { note: "A mile out, and one of the densest pockets of buildings with no washer in the apartment.", name: 'Cobble Hill', miles: 1.0 },
  { note: "The far side of the expressway, still inside the band. Red Hook has fewer laundromats per person than almost anywhere we serve.", name: 'Red Hook', miles: 1.0 },
  { note: "Up by the promenade, about a mile and a half out.", name: 'Brooklyn Heights', miles: 1.4 },
  { note: "South past the park. The whole neighborhood sits inside the band.", name: 'Prospect Lefferts Gardens', miles: 1.4 },
  { note: "North over the BQE, and closer in than most of Williamsburg proper.", name: 'South Williamsburg', miles: 1.6 },
  { note: "Behind the park, a straight run down.", name: 'Windsor Terrace', miles: 1.7 },
  { note: "The lower end of the Slope, well inside the band.", name: 'South Slope', miles: 1.7 },
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
