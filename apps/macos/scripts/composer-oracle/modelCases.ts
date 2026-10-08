// Provider catalog, model selection, option descriptors and the traits control.
import { createRequire } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { repoRoot } from "../lib/load.ts";
import type { Sources } from "./lib.ts";

type Case = { group: string; input: unknown; output: unknown };

const imp = (path: string) => import(pathToFileURL(join(repoRoot, path)).href);

function provider(input: {
  instanceId: string;
  driver: string;
  displayName?: string;
  enabled?: boolean;
  status?: string;
  availability?: string;
  accentColor?: string;
  models: unknown[];
  skills?: unknown[];
  slashCommands?: unknown[];
}) {
  return {
    instanceId: input.instanceId,
    driver: input.driver,
    ...(input.displayName ? { displayName: input.displayName } : {}),
    ...(input.accentColor ? { accentColor: input.accentColor } : {}),
    enabled: input.enabled ?? true,
    installed: true,
    status: input.status ?? "ready",
    ...(input.availability ? { availability: input.availability } : {}),
    auth: { status: "authenticated" },
    checkedAt: "2026-10-08T10:00:00.000Z",
    models: input.models,
    slashCommands: input.slashCommands ?? [],
    skills: input.skills ?? [],
  };
}

const select = (
  id: string,
  label: string,
  options: Array<[string, string, boolean?]>,
  extra: Record<string, unknown> = {},
) => ({
  id,
  label,
  type: "select",
  options: options.map(([optionId, optionLabel, isDefault]) => ({
    id: optionId,
    label: optionLabel,
    ...(isDefault ? { isDefault: true } : {}),
  })),
  ...extra,
});
const bool = (id: string, label: string, currentValue?: boolean) => ({
  id,
  label,
  type: "boolean",
  ...(currentValue === undefined ? {} : { currentValue }),
});
const model = (
  slug: string,
  name: string,
  extra: Record<string, unknown> = {},
  descriptors?: unknown[],
) => ({
  slug,
  name,
  isCustom: false,
  ...extra,
  ...(descriptors ? { capabilities: { optionDescriptors: descriptors } } : {}),
});

export const PROVIDERS = [
  provider({
    instanceId: "codex",
    driver: "codex",
    displayName: "Codex",
    models: [
      model("gpt-6-astra", "GPT-6 Astra", { isDefault: true, badge: "new" }, [
        select("reasoningEffort", "Reasoning", [
          ["low", "Low"],
          ["medium", "Medium", true],
          ["high", "High"],
        ]),
        select("serviceTier", "Service tier", [
          ["default", "Standard", true],
          ["fast", "Fast"],
        ]),
      ]),
      model("gpt-5.4", "GPT-5.4", { aliases: ["five-four"], shortName: "5.4" }, [
        select("reasoningEffort", "Reasoning", [
          ["low", "Low"],
          ["high", "High", true],
        ]),
      ]),
      model("my-custom", "My Custom", { isCustom: true }),
      model("legacy-1", "Legacy One", { isLegacy: true }),
    ],
    skills: [
      {
        name: "frontend-design",
        description: "Build UIs",
        path: "/home/u/.codex/skills/frontend-design",
        scope: "user",
        enabled: true,
        displayName: "Frontend Design",
        shortDescription: "Design frontends",
      },
      { name: "disabled-skill", path: "/x", enabled: false },
      { name: "agent-only", path: "/x", enabled: true, userInvocable: false },
      { name: "Frontend-Design", path: "/dup", enabled: true },
      {
        name: "plugin-skill",
        path: "/home/u/.codex/plugins/foo/skill",
        scope: "repo",
        enabled: true,
        description: "From a plugin",
      },
    ],
    slashCommands: [
      { name: "compact", description: "Compact the context" },
      { name: "review", input: { hint: "branch" } },
      { name: "frontend-design" },
    ],
  }),
  provider({
    instanceId: "codex_personal",
    driver: "codex",
    displayName: "Codex",
    accentColor: "#112233",
    models: [
      model("gpt-6-astra", "GPT-6 Astra", { isDefault: true }),
      model("personal-only", "Personal Only"),
    ],
  }),
  provider({
    instanceId: "claudeAgent",
    driver: "claudeAgent",
    displayName: "Claude",
    models: [
      model("claude-fable-5-1", "Claude Fable 5.1", { isDefault: true, aliases: ["fable"] }, [
        select(
          "effort",
          "Effort",
          [
            ["low", "Low"],
            ["medium", "Medium"],
            ["high", "High", true],
            ["ultrathink", "Ultrathink"],
          ],
          { promptInjectedValues: ["ultrathink"] },
        ),
        bool("thinking", "Thinking", true),
        bool("fastMode", "Fast mode"),
        select("contextWindow", "Context window", [
          ["200k", "200k", true],
          ["1m", "1M"],
        ]),
      ]),
      model("claude-haiku-4-5", "Claude Haiku 4.5", {}, [bool("fastMode", "Fast mode")]),
      model("plain", "Plain Model"),
    ],
  }),
  provider({
    instanceId: "opencode",
    driver: "opencode",
    displayName: "OpenCode",
    models: [
      model("openai/gpt-5", "GPT-5", { isDefault: true }, [
        select("agent", "Agent", [
          ["build", "Build", true],
          ["plan", "Plan"],
        ]),
        select("variant", "Variant", [
          ["a", "A"],
          ["b", "B", true],
        ]),
      ]),
      model("openai/gpt-5-mini", "GPT-5 mini", {}, [
        select("agent", "Agent", [["plan", "Plan", true]]),
      ]),
    ],
  }),
  provider({
    instanceId: "cursor",
    driver: "cursor",
    displayName: "Cursor",
    enabled: false,
    status: "disabled",
    models: [model("auto", "Auto", { isDefault: true })],
  }),
  provider({
    instanceId: "antigravity",
    driver: "antigravity",
    displayName: "Antigravity",
    availability: "unavailable",
    models: [model("antigravity-default", "Default", { isDefault: true })],
  }),
  provider({
    instanceId: "grok",
    driver: "grok",
    displayName: "Grok",
    status: "error",
    models: [model("grok-build", "Grok Build", { isDefault: true })],
  }),
];

export const SETTINGS = [
  {
    name: "default",
    planModeEnabled: false,
    providerInstances: {},
    providers: {},
    providerModelPreferences: {},
  },
  {
    name: "customized",
    planModeEnabled: true,
    providerInstances: {
      codex_personal: {
        enabled: true,
        config: {
          customModels: ["mine", { slug: "mine-2", name: "Mine Two" }, "gpt-6-astra", "mine"],
        },
      },
      claudeAgent: { enabled: true },
      opencode: { enabled: true },
      grok: { enabled: false },
    },
    providers: {
      codex: {
        enabled: true,
        customModels: ["legacy-custom", { slug: "my-custom", name: "My Custom" }],
      },
      cursor: { enabled: true },
      antigravity: { enabled: true },
    },
    providerModelPreferences: {
      codex: { hiddenModels: ["gpt-5.4"], modelOrder: ["legacy-1", "gpt-6-astra"] },
      opencode: { hiddenModels: ["openai/gpt-5-mini"], modelOrder: [] },
    },
  },
];

export async function modelCases(s: Sources): Promise<Case[]> {
  const out: Case[] = [];
  const add = (group: string, input: unknown, output: unknown) =>
    out.push({ group, input, output });
  const [
    instances,
    models,
    selection,
    draftStore,
    providerState,
    traits,
    picker,
    search,
    keys,
    ordering,
    skills,
    skillSearch,
    slashSearch,
  ] = await Promise.all([
    imp("apps/web/src/providerInstances.ts"),
    imp("apps/web/src/providerModels.ts"),
    imp("apps/web/src/modelSelection.ts"),
    imp("apps/web/src/composerDraftStore.ts"),
    imp("apps/web/src/components/chat/composerProviderState.tsx"),
    imp("apps/web/src/components/chat/TraitsPicker.tsx"),
    imp("apps/web/src/components/chat/modelPickerSearch.ts"),
    imp("packages/shared/src/searchRanking.ts"),
    imp("apps/web/src/components/chat/modelPickerKeys.ts"),
    imp("apps/web/src/modelOrdering.ts"),
    imp("packages/client-runtime/src/providerSkills.ts"),
    imp("apps/web/src/providerSkillSearch.ts"),
    imp("apps/web/src/components/chat/composerSlashCommandSearch.ts"),
  ]);
  void picker;
  void search;
  void keys;
  void ordering;
  add("catalog", {}, { providers: PROVIDERS, settings: SETTINGS });

  // constants
  const contracts = await imp("packages/contracts/src/index.ts");
  add(
    "modelConstants",
    {},
    {
      defaultModel: contracts.DEFAULT_MODEL,
      byProvider: contracts.DEFAULT_MODEL_BY_PROVIDER,
      aliases: contracts.MODEL_SLUG_ALIASES_BY_PROVIDER,
      display: contracts.PROVIDER_DISPLAY_NAMES,
      antigravity: contracts.ANTIGRAVITY_DEFAULT_MODEL,
    },
  );

  const providers = PROVIDERS as any[];
  const entriesOf = (settings: any) =>
    instances.sortProviderInstanceEntries(
      instances.applyProviderInstanceSettings(
        instances.deriveProviderInstanceEntries(providers),
        settings,
      ),
    );
  const brief = (entry: any) => ({
    instanceId: entry.instanceId,
    driverKind: entry.driverKind,
    displayName: entry.displayName,
    accentColor: entry.accentColor ?? null,
    enabled: entry.enabled,
    installed: entry.installed,
    status: entry.status,
    isDefault: entry.isDefault,
    isAvailable: entry.isAvailable,
    pickerReady: instances.isProviderInstancePickerReady(entry),
  });
  const selectedModels = [
    null,
    "",
    "gpt-6-astra",
    "GPT-6 ASTRA",
    "five-four",
    "gpt-5-codex",
    "5.4",
    "my-custom",
    "legacy-custom",
    "mine",
    "personal-only",
    "fable",
    "claude-haiku-4-5",
    "openai/gpt-5-mini",
    "unknown-model",
    "  gpt-5.4  ",
    "antigravity-default",
    "grok-build",
    "auto",
  ];

  SETTINGS.forEach((settings, settingsIndex) => {
    const entries = entriesOf(settings);
    add("providerEntries", { settingsIndex }, entries.map(brief));
    // the Swift side feeds the same raw entries order as `deriveProviderInstanceEntries` -> apply -> sort
    for (const entry of entries) {
      for (const selected of [null, "gpt-5.4", "unknown-model", "openai/gpt-5-mini"]) {
        const options = selection.getAppModelOptionsForInstance(settings, entry, selected);
        add(
          "modelOptions",
          { settingsIndex, instanceId: entry.instanceId, selected },
          options.map((o: any) => ({
            slug: o.slug,
            name: o.name,
            isCustom: o.isCustom,
            isDefault: o.isDefault ?? false,
            isLegacy: o.isLegacy ?? false,
            isUnavailable: o.isUnavailable ?? false,
            shortName: o.shortName ?? null,
            badge: o.badge ?? null,
          })),
        );
      }
      for (const selectedModel of selectedModels)
        for (const preserve of [false, true]) {
          add(
            "resolveInstanceModel",
            { settingsIndex, instanceId: entry.instanceId, selectedModel, preserve },
            selection.resolveAppModelSelectionForInstance(
              entry.instanceId,
              settings,
              providers,
              selectedModel,
              { preserveUnavailableSelection: preserve },
            ),
          );
        }
    }
    for (const driver of [
      "codex",
      "claudeAgent",
      "opencode",
      "cursor",
      "antigravity",
      "grok",
      "missing",
    ]) {
      for (const selectedModel of selectedModels)
        add(
          "resolveDriverModel",
          { settingsIndex, driver, selectedModel },
          selection.resolveAppModelSelection(driver, settings, providers, selectedModel),
        );
      add(
        "driverDefaults",
        { driver },
        {
          selectable: models.resolveSelectableProvider(providers, driver),
          defaultModel: models.getDefaultServerModel(providers, driver),
        },
      );
    }
    for (const instanceId of [
      "codex",
      "codex_personal",
      "claudeAgent",
      "opencode",
      "cursor",
      "antigravity",
      "grok",
      "gone",
      undefined,
    ]) {
      add(
        "selectableInstance",
        { settingsIndex, instanceId },
        {
          selectable: instances.resolveSelectableProviderInstance(providers, instanceId) ?? null,
          defaultModel: instanceId
            ? (instances.getDefaultProviderInstanceModel(providers, instanceId) ?? null)
            : null,
          defaultSelection: instances.resolveDefaultProviderModelSelection(
            providers,
            instanceId ? { instanceId, model: "x" } : null,
          ),
        },
      );
    }
  });

  // provider state and traits
  const optionSets: Array<unknown[] | null> = [
    null,
    [],
    [{ id: "effort", value: "low" }],
    [{ id: "effort", value: "ultrathink" }],
    [
      { id: "fastMode", value: true },
      { id: "thinking", value: false },
    ],
    [
      { id: "reasoningEffort", value: "high" },
      { id: "serviceTier", value: "fast" },
    ],
    [{ id: "agent", value: "plan" }],
    [
      { id: "agent", value: "build" },
      { id: "variant", value: "a" },
    ],
    [{ id: "effort", value: "bogus" }],
  ];
  for (const entry of entriesOf(SETTINGS[0]!)) {
    for (const slug of [...entry.models.map((m: any) => m.slug), "not-a-model"]) {
      for (const modelOptions of optionSets)
        for (const planModeEnabled of [false, true])
          for (const prompt of ["hello", "please ultrathink this"]) {
            const input = {
              instanceId: entry.instanceId,
              model: slug,
              modelOptions,
              planModeEnabled,
              prompt,
            };
            const state = providerState.getComposerProviderState({
              provider: entry.driverKind,
              model: slug,
              models: entry.models,
              modelOptions: modelOptions ?? undefined,
              promptInjectionState: s.model.isClaudeUltrathinkPrompt(prompt)
                ? "ultrathink"
                : "none",
              planModeEnabled,
            });
            add("providerState", input, {
              promptEffort: state.promptEffort,
              modelOptionsForDispatch: state.modelOptionsForDispatch ?? null,
              ultrathink: state.composerFrameClassName !== undefined,
            });
            const shouldRender = traits.shouldRenderTraitsControls({
              provider: entry.driverKind,
              models: entry.models,
              model: slug,
              prompt,
              modelOptions: modelOptions ?? undefined,
              planModeEnabled,
            });
            const caps = models.getProviderModelCapabilities(
              entry.models,
              slug,
              entry.driverKind,
              planModeEnabled,
            );
            const descriptors = s.model.getProviderOptionDescriptors({
              caps,
              selections: modelOptions ?? undefined,
            });
            const primary = descriptors.find((d: any) => d.type === "select");
            const ultrathinkControlled =
              (primary?.promptInjectedValues?.length ?? 0) > 0 &&
              s.model.isClaudeUltrathinkPrompt(prompt);
            const display = traits.buildTraitsTriggerDisplay({
              provider: entry.driverKind,
              descriptors,
              primarySelectDescriptorId: primary?.id ?? null,
              ultrathinkPromptControlled: ultrathinkControlled,
            });
            add("traits", input, { shouldRender, display });
          }
    }
  }

  // effective draft model state
  const drafts: Array<Record<string, unknown>> = [
    {},
    {
      codex: {
        instanceId: "codex",
        model: "gpt-5.4",
        options: [{ id: "reasoningEffort", value: "high" }],
      },
    },
    {
      claudeAgent: {
        instanceId: "claudeAgent",
        model: "fable",
        options: [{ id: "effort", value: "low" }],
      },
      codex_personal: { instanceId: "codex_personal", model: "personal-only" },
    },
    { opencode: { instanceId: "opencode", model: "openai/gone" } },
    { codex: { instanceId: "codex", model: "unknown" } },
  ];
  const thread = [
    null,
    { instanceId: "codex", model: "gpt-5.4", options: [{ id: "reasoningEffort", value: "low" }] },
    { instanceId: "claudeAgent", model: "claude-haiku-4-5" },
    { instanceId: "opencode", model: "openai/gone" },
  ];
  SETTINGS.forEach((settings, settingsIndex) => {
    for (const draft of drafts)
      for (const threadSelection of thread)
        for (const projectSelection of [
          null,
          { instanceId: "codex", model: "gpt-5.4", options: [{ id: "x", value: true }] },
        ])
          for (const [selectedProvider, selectedInstanceId] of [
            ["codex", "codex"],
            ["codex", "codex_personal"],
            ["claudeAgent", "claudeAgent"],
            ["opencode", "opencode"],
            ["antigravity", "antigravity"],
            ["codex", null],
            ["cursor", "cursor"],
          ] as const) {
            const state = draftStore.deriveEffectiveComposerModelState({
              draft: { modelSelectionByProvider: draft, activeProvider: null },
              providers,
              selectedProvider,
              selectedInstanceId,
              threadModelSelection: threadSelection,
              projectModelSelection: projectSelection,
              settings,
            });
            add(
              "effectiveModel",
              {
                settingsIndex,
                draft,
                threadSelection,
                projectSelection,
                selectedProvider,
                selectedInstanceId,
              },
              { selectedModel: state.selectedModel, modelOptions: state.modelOptions },
            );
          }
  });

  // picker search and keys
  const searchable = [
    { driverKind: "codex", providerDisplayName: "Codex", name: "GPT-6 Astra", shortName: "Astra" },
    {
      driverKind: "codex",
      providerDisplayName: "Codex Personal",
      name: "GPT-5.4",
      subProvider: "OpenAI",
      isFavorite: true,
    },
    { driverKind: "claudeAgent", providerDisplayName: "Claude", name: "Claude Fable 5.1" },
    {
      driverKind: "opencode",
      providerDisplayName: "OpenCode",
      name: "GPT-5 mini",
      subProvider: "openai",
    },
  ];
  for (const query of [
    "",
    "  ",
    "astra",
    "codex",
    "codex personal",
    "gpt 5",
    "5.4",
    "fab",
    "clde",
    "openai mini",
    "zzz",
    "c",
    "GPT-6",
    "  claude  fable ",
  ]) {
    for (const model of searchable)
      add("pickerSearch", { model, query }, picker.scoreModelPickerSearch(model, query));
  }
  for (const [instanceId, slug] of [
    ["codex", "gpt-6"],
    ["codex_personal", "x:y"],
    ["", "x"],
    ["é", "ü"],
  ] as const) {
    const key = keys.modelPickerModelKey(instanceId, slug);
    add(
      "pickerKeys",
      { instanceId, slug },
      {
        key,
        parsed: keys.parseModelPickerModelKey(key),
        legacy: keys.modelPickerLegacySectionKey(instanceId),
        parsedLegacy: keys.parseModelPickerLegacySectionKey(
          keys.modelPickerLegacySectionKey(instanceId),
        ),
      },
    );
  }
  for (const key of [
    "model:",
    "model:x",
    "model:3:ab",
    "model:2:abcd",
    "model:a:b",
    "legacy-models:",
    "other",
  ])
    add(
      "pickerKeys",
      { key },
      {
        parsed: keys.parseModelPickerModelKey(key),
        parsedLegacy: keys.parseModelPickerLegacySectionKey(key),
      },
    );

  // skills and slash commands
  const codexSkills = providers[0].skills;
  add(
    "skillHelpers",
    {},
    {
      names: codexSkills.map((skill: any) => skills.formatProviderSkillDisplayName(skill)),
      invocable: codexSkills.map((skill: any) => skills.isProviderSkillUserInvocable(skill)),
      deduped: skills.dedupeProviderSkillsByName(codexSkills).map((skill: any) => skill.name),
      sourceKinds: codexSkills.map((skill: any) => skills.resolveProviderSkillSourceKind(skill)),
      slashMenuOn: skills
        .getProviderSkillsForSlashMenu(codexSkills, true)
        .map((skill: any) => skill.name),
      slashMenuOff: skills
        .getProviderSkillsForSlashMenu(codexSkills, false)
        .map((skill: any) => skill.name),
      commands: skills
        .getProviderSlashCommandsForSlashMenu(
          providers[0].slashCommands,
          skills.getProviderSkillsForSlashMenu(codexSkills, true),
        )
        .map((command: any) => command.name),
    },
  );
  for (const query of [
    "",
    "front",
    "$front",
    "€plug",
    "design",
    "FRONT-design",
    "ui",
    "user",
    "repo",
    "zzz",
    "a",
  ]) {
    add(
      "skillSearch",
      { query },
      skillSearch.searchProviderSkills(codexSkills, query).map((skill: any) => skill.name),
    );
  }
  const slashItems = [
    {
      id: "slash:model",
      type: "slash-command",
      command: "model",
      label: "/model",
      description: "Switch response model for this thread",
    },
    {
      id: "slash:plan",
      type: "slash-command",
      command: "plan",
      label: "/plan",
      description: "Switch this thread into plan mode",
    },
    {
      id: "slash:default",
      type: "slash-command",
      command: "default",
      label: "/default",
      description: "Switch this thread back to normal build mode",
    },
    ...providers[0].slashCommands.map((command: any) => ({
      id: `provider-slash-command:codex:${command.name}`,
      type: "provider-slash-command",
      provider: "codex",
      command,
      label: `/${command.name}`,
      description: command.description ?? command.input?.hint ?? "Run provider command",
    })),
    ...skills
      .getProviderSkillsForSlashMenu(codexSkills, true)
      .map((skill: any) => ({
        id: `skill:codex:${skill.name}`,
        type: "skill",
        provider: "codex",
        skill,
        label: `/skill:${skill.name}`,
        description:
          skill.shortDescription ??
          skill.description ??
          (skill.scope ? `${skill.scope} skill` : ""),
      })),
  ];
  for (const query of [
    "",
    "/",
    "mod",
    "model",
    "plan",
    "def",
    "co",
    "skill",
    "skill:",
    "skill:front",
    "front",
    "zzz",
    "/rev",
    "branch",
    "compact",
  ]) {
    for (const atStart of [true, false]) {
      const items = slashSearch.slashCommandItemsForPromptPosition(slashItems as any, atStart);
      add(
        "slashSearch",
        { query, atStart },
        slashSearch.searchSlashCommandItems(items, query).map((item: any) => item.id),
      );
    }
  }
  return out;
}
