'use strict';

const fs = require('fs');
const path = require('path');
const { getCredential } = require('./credential-store');

const DEFAULT_CONFIGURATION = Object.freeze({
  schemaVersion: 1,
  provider: 'replicate',
  defaultModel: 'nano-banana-pro',
  credentialId: 'provider:replicate',
  models: {
    'nano-banana-pro': { id: 'google/nano-banana-pro', label: 'Nano Banana Pro', resolution: '2K', outputFormat: 'png', allowFallback: false }
  }
});

function loadImageConfiguration(root) {
  const file = path.join(root, 'config', 'image-generators.json');
  let configured = {};
  try { configured = JSON.parse(fs.readFileSync(file, 'utf8')); } catch {}
  return {
    ...DEFAULT_CONFIGURATION,
    ...configured,
    models: { ...DEFAULT_CONFIGURATION.models, ...(configured.models || {}) }
  };
}

function replicateToken(configuration) {
  return getCredential(configuration.credentialId || 'provider:replicate') || process.env.REPLICATE_API_TOKEN || null;
}

function resolveImageModel(configuration, requested) {
  const token = String(requested || configuration.defaultModel || 'nano-banana-pro').trim().toLowerCase();
  const profile = configuration.models?.[token];
  const id = profile?.id || token;
  if (!/^[a-z0-9][a-z0-9_.-]{0,79}\/[a-z0-9][a-z0-9_.-]{0,79}$/i.test(id)) {
    throw new Error(`Image model “${requested || token}” is not a configured alias or valid Replicate owner/model identifier.`);
  }
  return { alias: profile ? token : null, id, ...(profile || {}) };
}

function estimateImageCost(configuration, requestedModel, resolution) {
  const model = resolveImageModel(configuration, requestedModel);
  const size = String(resolution || model.resolution || '2K').toUpperCase();
  if (model.id === 'google/nano-banana-pro') return { currency: 'USD', amount: size === '4K' ? 0.30 : 0.15, basis: `${size} output image` };
  return { currency: 'USD', amount: null, basis: 'Replicate does not expose predictable pricing for this override through the model schema' };
}

async function replicateRequest(token, url, options = {}) {
  const response = await fetch(url, { ...options, headers: { authorization: `Bearer ${token}`, ...(options.headers || {}) } });
  const text = await response.text();
  let data; try { data = JSON.parse(text); } catch { data = null; }
  if (!response.ok) throw new Error(data?.detail || data?.error || `Replicate returned HTTP ${response.status}.`);
  return data;
}

function looksLikeImageModel(item) {
  const text = `${item?.owner || ''}/${item?.name || ''} ${item?.description || ''} ${item?.metadata?.generated_description || ''} ${(item?.metadata?.tags || []).join(' ')}`.toLowerCase();
  return /image|text.to.image|illustration|photo|visual|flux|imagen|banana|stable diffusion|seedream/.test(text)
    && !/video|caption|classification|detect|segment|embedding|upscal|face swap|speech/.test(text);
}

async function searchReplicateImageModels(root, query = 'image generation') {
  const configuration = loadImageConfiguration(root);
  const token = replicateToken(configuration);
  if (!token) {
    const configured = Object.entries(configuration.models).map(([alias, model]) => ({ alias, id: model.id, name: model.label || alias, description: 'Configured image model' }));
    return { live: false, models: configured, notice: 'Add a Replicate API token to search Replicate’s live catalog.' };
  }
  const wanted = String(query || 'image generation').trim().slice(0, 120);
  const url = `https://api.replicate.com/v1/search?query=${encodeURIComponent(wanted)}&limit=50`;
  const data = await replicateRequest(token, url);
  const results = (data?.models || data?.results || []).filter(looksLikeImageModel).slice(0, 30).map(item => ({
    id: `${item.owner}/${item.name}`, name: item.name, owner: item.owner, description: item.description || item.metadata?.generated_description || '',
    runs: Number(item.run_count || 0), url: item.url || `https://replicate.com/${item.owner}/${item.name}`
  }));
  return { live: true, query: wanted, models: results };
}

async function runReplicateImage(root, request) {
  const configuration = loadImageConfiguration(root);
  const token = replicateToken(configuration);
  if (!token) throw new Error('Replicate is not configured. Add its API token in Image generator settings on the computer running Demi.');
  const model = resolveImageModel(configuration, request.model);
  const proposedInput = {
    prompt: String(request.prompt || '').trim(),
    output_format: String(request.outputFormat || model.outputFormat || 'png').toLowerCase()
  };
  if (!proposedInput.prompt) throw new Error('An image description is required.');
  if (request.aspectRatio) proposedInput.aspect_ratio = request.aspectRatio;
  if (request.resolution || model.resolution) proposedInput.resolution = request.resolution || model.resolution;
  if (Array.isArray(request.referenceImages) && request.referenceImages.length) {
    proposedInput.image_input = request.referenceImages.map(item => `data:${item.mime};base64,${item.bytes.toString('base64')}`);
  }
  if (model.id === 'google/nano-banana-pro') proposedInput.allow_fallback_model = request.allowFallback === true || model.allowFallback === true;
  // Replicate models use different input schemas. Keep common controls only when
  // the selected model advertises them, which makes owner/model overrides useful
  // without pretending every image model accepts Nano Banana's parameters.
  const metadata = await replicateRequest(token, `https://api.replicate.com/v1/models/${model.id}`);
  const properties = metadata?.latest_version?.openapi_schema?.components?.schemas?.Input?.properties
    || metadata?.latest_version?.openapi_schema?.components?.schemas?.PredictionRequest?.properties?.input?.properties
    || null;
  const input = properties ? Object.fromEntries(Object.entries(proposedInput).filter(([key]) => Object.hasOwn(properties, key))) : proposedInput;
  if (!Object.hasOwn(input, 'prompt')) throw new Error(`Replicate model ${model.id} does not advertise a text prompt input and cannot be used by /image.`);
  const url = `https://api.replicate.com/v1/models/${model.id}/predictions`;
  let prediction = await replicateRequest(token, url, { method: 'POST', headers: { 'content-type': 'application/json', prefer: 'wait=60' }, body: JSON.stringify({ input }) });
  const deadline = Date.now() + 5 * 60 * 1000;
  while (!['succeeded','failed','canceled'].includes(prediction.status) && Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 1500));
    prediction = await replicateRequest(token, prediction.urls?.get || `https://api.replicate.com/v1/predictions/${prediction.id}`);
  }
  if (prediction.status !== 'succeeded') throw new Error(prediction.error || `Replicate image generation ${prediction.status || 'timed out'}.`);
  const outputUrl = Array.isArray(prediction.output) ? prediction.output[0] : prediction.output;
  if (!/^https:\/\//i.test(String(outputUrl || ''))) throw new Error('Replicate returned no downloadable image.');
  const output = await fetch(outputUrl);
  if (!output.ok) throw new Error(`Generated image download returned HTTP ${output.status}.`);
  const bytes = Buffer.from(await output.arrayBuffer());
  if (!bytes.length || bytes.length > 25 * 1024 * 1024) throw new Error('Generated image was empty or exceeded Demi’s 25 MB image limit.');
  return { bytes, model, predictionId: prediction.id, metrics: prediction.metrics || {}, outputUrl, input };
}

module.exports = { loadImageConfiguration, resolveImageModel, estimateImageCost, searchReplicateImageModels, runReplicateImage };
