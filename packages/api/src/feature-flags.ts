import { Schema } from "effect"

export const FEATURE_FLAGS_NAMESPACE = "feature-flags"

export const FeatureFlagState = Schema.Struct({
  id: Schema.String,
  title: Schema.String,
  description: Schema.String,
  enabled: Schema.Boolean
})
export type FeatureFlagState = typeof FeatureFlagState.Type

export const FeatureFlagsResponse = Schema.Struct({ flags: Schema.Array(FeatureFlagState) })
export type FeatureFlagsResponse = typeof FeatureFlagsResponse.Type

export const SetFeatureFlagRequest = Schema.Struct({ enabled: Schema.Boolean })
export type SetFeatureFlagRequest = typeof SetFeatureFlagRequest.Type
