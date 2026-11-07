// ============================================================================
// §1 IMPORTS AND CONSTANTS
// ============================================================================
import { useEffect, useRef, useState } from 'react';
import { jsx, jsxs } from 'react/jsx-runtime';
import {
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  ErrorState,
  GlyphSpinner,
  PALETTE_AREA,
  ROUTES_AREA,
  SIDEBAR_NAV_AREA,
  STATUSBAR_AREAS,
  StatusDot,
  Switch,
  atom,
  host,
  queryClient,
  useQuery,
  useValue,
  writeClipboardText,
} from '@hermes/plugin-sdk';

const PLUGIN_ID = 'hermes-sysadmin';
const ROUTE = '/hermes-sysadmin';
const CHANGED_EVENT = 'plugin.hermes-sysadmin.changed';
// Agent plugins with a config_schema get an automatic Settings page at this route.
const SETTINGS_HREF = '/settings?tab=plugins&agent=hermes-sysadmin';
const OP_TIMEOUT_MS = 120000;
const POLL = { health: 60000, overview: 60000, list: 60000, sessions: 30000, backups: 60000, job: 5000, audit: 30000, fleet: 300000 };

// The PluginContext handed to register(); every component runs after register().
let CTX = null;

