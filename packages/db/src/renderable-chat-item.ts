export const renderableChatItem = (item: string): string => `(
  ${item}.status = 'streaming'
  or ${item}.has_details = 1
  or length(coalesce(${item}.stop_reason, '')) > 0
  or length(coalesce(${item}.stop_detail, '')) > 0
  or (${item}.attachments is not null and ${item}.attachments != '[]')
  or exists (
    select 1 from chat_parts as renderable_part
    where renderable_part.item_id = ${item}.id
      and length(coalesce(renderable_part.text, '')) > 0
  )
)`
