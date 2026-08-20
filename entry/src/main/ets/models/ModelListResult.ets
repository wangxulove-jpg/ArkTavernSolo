export interface ModelListItem {
  readonly id: string;
  readonly ownedBy: string;
}

export interface ModelListResult {
  readonly models: ModelListItem[];
  readonly source: 'api' | 'preset';
}
